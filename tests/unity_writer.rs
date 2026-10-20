use codestrike::unity_writer::{GateError, LeaseState, UnityMutationGate, UnityTarget};

fn target(instance: &str) -> UnityTarget {
    UnityTarget {
        project_id: "fixture-project".into(),
        instance_id: instance.into(),
    }
}

#[test]
fn one_writer_per_project_instance_and_stale_completion_is_rejected() {
    let mut gate = UnityMutationGate::new();
    let first = target("editor-1");
    let second = target("editor-2");
    let first_lease = gate.acquire(&first).unwrap();
    assert_eq!(gate.acquire(&first), Err(GateError::Busy));
    let second_lease = gate.acquire(&second).unwrap();
    assert_eq!(
        gate.finish_known(&first, second_lease),
        Err(GateError::StaleLease)
    );
    assert_eq!(gate.state(&first), LeaseState::Active(first_lease));
    gate.finish_known(&first, first_lease).unwrap();
    assert_eq!(gate.state(&first), LeaseState::Available);
    assert_ne!(gate.acquire(&first).unwrap(), first_lease);
}

#[test]
fn transport_loss_blocks_retries_until_inspection() {
    let mut gate = UnityMutationGate::new();
    let target = target("editor-1");
    let id = gate.acquire(&target).unwrap();
    gate.mark_outcome_unknown(&target, id).unwrap();
    assert_eq!(gate.state(&target), LeaseState::OutcomeUnknown(id));
    assert_eq!(gate.acquire(&target), Err(GateError::InspectionRequired));
    assert_eq!(gate.finish_known(&target, id), Err(GateError::StaleLease));
    assert_eq!(
        gate.release_after_inspection(&target, id, false),
        Err(GateError::InspectionRequired)
    );
    assert_eq!(gate.state(&target), LeaseState::OutcomeUnknown(id));
    gate.release_after_inspection(&target, id, true).unwrap();
    assert!(gate.acquire(&target).is_ok());
}

#[test]
fn missing_identity_cannot_acquire_a_mutation_lease() {
    let mut gate = UnityMutationGate::new();
    assert_eq!(gate.acquire(&target(" ")), Err(GateError::InvalidTarget));
}
