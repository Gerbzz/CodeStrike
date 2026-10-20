//! In-memory mutation lease contract for a future local Unity MCP host.
//! No Unity process, MCP client, or external service is used here.

use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct UnityTarget {
    pub project_id: String,
    pub instance_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LeaseId(u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LeaseState {
    Available,
    Active(LeaseId),
    OutcomeUnknown(LeaseId),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GateError {
    InvalidTarget,
    Busy,
    InspectionRequired,
    StaleLease,
}

/// The host must map target IDs to a verified local Unity project and editor
/// instance, and serialize all mutating tool calls through this gate.
#[derive(Default)]
pub struct UnityMutationGate {
    next_id: u64,
    states: HashMap<UnityTarget, LeaseState>,
}

impl UnityMutationGate {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn state(&self, target: &UnityTarget) -> LeaseState {
        self.states
            .get(target)
            .copied()
            .unwrap_or(LeaseState::Available)
    }

    pub fn acquire(&mut self, target: &UnityTarget) -> Result<LeaseId, GateError> {
        if target.project_id.trim().is_empty() || target.instance_id.trim().is_empty() {
            return Err(GateError::InvalidTarget);
        }
        match self.state(target) {
            LeaseState::Active(_) => return Err(GateError::Busy),
            LeaseState::OutcomeUnknown(_) => return Err(GateError::InspectionRequired),
            LeaseState::Available => {}
        }
        self.next_id = self.next_id.checked_add(1).ok_or(GateError::Busy)?;
        let id = LeaseId(self.next_id);
        self.states.insert(target.clone(), LeaseState::Active(id));
        Ok(id)
    }

    /// Called only after an unambiguous MCP result was received and checked.
    pub fn finish_known(&mut self, target: &UnityTarget, id: LeaseId) -> Result<(), GateError> {
        match self.state(target) {
            LeaseState::Active(current) if current == id => {
                self.states.remove(target);
                Ok(())
            }
            _ => Err(GateError::StaleLease),
        }
    }

    /// A timeout, domain reload, or lost transport must block another write.
    pub fn mark_outcome_unknown(
        &mut self,
        target: &UnityTarget,
        id: LeaseId,
    ) -> Result<(), GateError> {
        match self.state(target) {
            LeaseState::Active(current) if current == id => {
                self.states
                    .insert(target.clone(), LeaseState::OutcomeUnknown(id));
                Ok(())
            }
            _ => Err(GateError::StaleLease),
        }
    }

    /// The host can release an uncertain lease only after inspecting the
    /// project/editor state and recording a user-reviewed reconciliation.
    pub fn release_after_inspection(
        &mut self,
        target: &UnityTarget,
        id: LeaseId,
        inspected: bool,
    ) -> Result<(), GateError> {
        if !inspected {
            return Err(GateError::InspectionRequired);
        }
        match self.state(target) {
            LeaseState::OutcomeUnknown(current) if current == id => {
                self.states.remove(target);
                Ok(())
            }
            _ => Err(GateError::StaleLease),
        }
    }
}
