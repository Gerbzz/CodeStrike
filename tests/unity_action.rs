use codestrike::unity_action::{
    ActionGateError, UnityAction, UnityActionRequest, UnityCheckpoint, UnitySnapshot,
    prepare_unity_action,
};
use codestrike::unity_writer::{GateError, LeaseState, UnityMutationGate, UnityTarget};

fn fixture(dirty: bool) -> (UnitySnapshot, UnityActionRequest) {
    let target = UnityTarget {
        project_id: "project-guid".into(),
        instance_id: "editor-session".into(),
    };
    let snapshot = UnitySnapshot {
        target: target.clone(),
        revision: "scene-and-asset-revision-7".into(),
        known_scene_ids: vec!["scene-guid".into()],
        known_object_ids: vec!["existing-object-id".into()],
        dirty_scene_ids: if dirty {
            vec!["scene-guid".into()]
        } else {
            vec![]
        },
    };
    let request = UnityActionRequest {
        target,
        expected_revision: snapshot.revision.clone(),
        checkpoint: UnityCheckpoint {
            id: "checkpoint-7".into(),
            revision: snapshot.revision.clone(),
            includes_unsaved_scenes: !dirty,
        },
        action: UnityAction::CreateGameObject {
            scene_id: "scene-guid".into(),
            parent_object_id: None,
            name: "Player".into(),
        },
    };
    (snapshot, request)
}

#[test]
fn requires_matching_revision_and_checkpoint_before_granting_a_writer() {
    let (snapshot, mut request) = fixture(false);
    let mut gate = UnityMutationGate::new();
    request.expected_revision = "stale".into();
    assert_eq!(
        prepare_unity_action(&mut gate, &snapshot, request.clone()),
        Err(ActionGateError::StaleRevision)
    );
    assert_eq!(gate.state(&snapshot.target), LeaseState::Available);
    request.expected_revision = snapshot.revision.clone();
    request.checkpoint.id.clear();
    assert_eq!(
        prepare_unity_action(&mut gate, &snapshot, request),
        Err(ActionGateError::MissingCheckpoint)
    );
    assert_eq!(gate.state(&snapshot.target), LeaseState::Available);
}

#[test]
fn unsaved_scene_requires_a_checkpoint_that_covers_memory_state() {
    let (snapshot, mut request) = fixture(true);
    let mut gate = UnityMutationGate::new();
    assert_eq!(
        prepare_unity_action(&mut gate, &snapshot, request.clone()),
        Err(ActionGateError::UnsavedSceneNotCovered)
    );
    request.checkpoint.includes_unsaved_scenes = true;
    let prepared = prepare_unity_action(&mut gate, &snapshot, request).unwrap();
    assert!(matches!(
        gate.state(&snapshot.target),
        LeaseState::Active(_)
    ));
    prepared.finish_known(&mut gate).unwrap();
    assert_eq!(gate.state(&snapshot.target), LeaseState::Available);
}

#[test]
fn wrong_instance_and_ambiguous_result_block_further_actions() {
    let (snapshot, mut request) = fixture(false);
    let mut gate = UnityMutationGate::new();
    request.target.instance_id = "other-editor".into();
    assert_eq!(
        prepare_unity_action(&mut gate, &snapshot, request.clone()),
        Err(ActionGateError::WrongInstance)
    );
    request.target = snapshot.target.clone();
    let prepared = prepare_unity_action(&mut gate, &snapshot, request.clone()).unwrap();
    assert_eq!(
        prepare_unity_action(&mut gate, &snapshot, request.clone()),
        Err(ActionGateError::Writer(GateError::Busy))
    );
    prepared.outcome_unknown(&mut gate).unwrap();
    assert_eq!(
        prepare_unity_action(&mut gate, &snapshot, request),
        Err(ActionGateError::Writer(GateError::InspectionRequired))
    );
}

#[test]
fn object_references_must_exist_in_the_snapshot() {
    let (snapshot, mut request) = fixture(false);
    let mut gate = UnityMutationGate::new();
    request.action = UnityAction::SetGameObjectActive {
        scene_id: "scene-guid".into(),
        object_id: "missing-object".into(),
        active: false,
    };
    assert_eq!(
        prepare_unity_action(&mut gate, &snapshot, request),
        Err(ActionGateError::InvalidRequest)
    );
    assert_eq!(gate.state(&snapshot.target), LeaseState::Available);
}
