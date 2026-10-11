//! Owns every process launched by an explicit Cargo action. Windows uses a
//! Job Object and starts Cargo suspended so it cannot launch a child before
//! assignment. Other targets fail closed until their process-tree lifecycle is
//! implemented and tested.

use std::io;
use std::process::{Child, Command};

#[cfg(windows)]
mod platform {
    use super::*;
    use std::os::windows::io::AsRawHandle;
    use std::os::windows::process::CommandExt;
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
    };
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, JobObjectExtendedLimitInformation,
        SetInformationJobObject, TerminateJobObject,
    };
    use windows_sys::Win32::System::Threading::{
        CREATE_SUSPENDED, OpenThread, ResumeThread, THREAD_SUSPEND_RESUME,
    };

    pub struct ProcessScope { job: HANDLE }
    impl ProcessScope {
        pub fn spawn(mut command: Command) -> io::Result<(Child, Self)> {
            // SAFETY: null attributes/name request an unnamed job owned only here.
            let job = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
            if job.is_null() { return Err(io::Error::last_os_error()); }
            let scope = Self { job };
            // SAFETY: zeroed is valid for this POD Win32 limit structure.
            let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            // SAFETY: the pointer and size describe `limits` for the duration of the call.
            if unsafe {
                SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                    (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                    std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32)
            } == 0 { return Err(io::Error::last_os_error()); }
            command.creation_flags(CREATE_SUSPENDED);
            let mut child = command.spawn()?;
            // SAFETY: `child` is a live process handle from this Command::spawn.
            if unsafe { AssignProcessToJobObject(job, child.as_raw_handle() as HANDLE) } == 0 {
                let error = io::Error::last_os_error();
                let _ = child.kill(); let _ = child.wait();
                return Err(error);
            }
            if let Err(error) = resume_initial_thread(child.id()) {
                scope.stop(&mut child);
                return Err(error);
            }
            Ok((child, scope))
        }
        pub fn stop(&self, child: &mut Child) {
            // SAFETY: this handle names only the Job Object created for this invocation.
            unsafe { TerminateJobObject(self.job, 1); }
            let _ = child.kill();
            let _ = child.wait();
        }
    }
    impl Drop for ProcessScope {
        fn drop(&mut self) {
            // The kill-on-close limit also catches descendants after Cargo exits.
            // SAFETY: `job` is owned by this value and closed exactly once.
            unsafe { CloseHandle(self.job); }
        }
    }

    fn resume_initial_thread(pid: u32) -> io::Result<()> {
        // SAFETY: the snapshot is read with the documented THREADENTRY32 size.
        let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) };
        if snapshot == INVALID_HANDLE_VALUE { return Err(io::Error::last_os_error()); }
        let mut entry = THREADENTRY32 { dwSize: std::mem::size_of::<THREADENTRY32>() as u32, ..Default::default() };
        let mut found = false;
        // SAFETY: snapshot and entry remain valid during enumeration.
        let mut more = unsafe { Thread32First(snapshot, &mut entry) };
        while more != 0 {
            if entry.th32OwnerProcessID == pid {
                // SAFETY: this thread ID belongs to the suspended child PID.
                let thread = unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID) };
                if thread.is_null() { unsafe { CloseHandle(snapshot); } return Err(io::Error::last_os_error()); }
                // SAFETY: OpenThread returned a live handle, closed below.
                let count = unsafe { ResumeThread(thread) };
                unsafe { CloseHandle(thread); }
                if count == u32::MAX { unsafe { CloseHandle(snapshot); } return Err(io::Error::last_os_error()); }
                found = true;
                break;
            }
            // SAFETY: advances the same snapshot enumeration.
            more = unsafe { Thread32Next(snapshot, &mut entry) };
        }
        unsafe { CloseHandle(snapshot); }
        if found { Ok(()) } else { Err(io::Error::new(io::ErrorKind::NotFound, "suspended Cargo thread not found")) }
    }
}

#[cfg(not(windows))]
mod platform {
    use super::*;
    pub struct ProcessScope;
    impl ProcessScope {
        pub fn spawn(_command: Command) -> io::Result<(Child, Self)> {
            Err(io::Error::new(io::ErrorKind::Unsupported, "process-tree isolation unavailable"))
        }
        pub fn stop(&self, _child: &mut Child) {}
    }
}

pub use platform::ProcessScope;
