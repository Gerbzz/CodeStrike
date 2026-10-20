//! Source-only contract between a future Unity context reader and action host.
//! This module does not connect to Unity or perform an action.

use crate::unity_writer::{GateError, LeaseId, UnityMutationGate, UnityTarget};

/// A host-produced token for one observed Unity project/instance state. The
/// host must regenerate it when scenes, assets, or relevant editor state change.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnitySnapshot {
    pub target: UnityTarget,
    pub revision: String,
    pub known_scene_ids: Vec<String>,
    pub known_object_ids: Vec<String>,
    pub dirty_scene_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnityCheckpoint {
    pub id: String,
    pub revision: String,
    pub includes_unsaved_scenes: bool,
}

/// Deliberately small first set; each variant needs a Unity-side validator and
/// an undo/restore implementation before any runtime support is enabled.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UnityAction {
    CreateGameObject {
        scene_id: String,
        parent_object_id: Option<String>,
        name: String,
    },
    SetGameObjectActive {
        scene_id: String,
        object_id: String,
        active: bool,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnityActionRequest {
    pub target: UnityTarget,
    pub expected_revision: String,
    pub checkpoint: UnityCheckpoint,
    pub action: UnityAction,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActionGateError {
    InvalidRequest,
    WrongInstance,
    StaleRevision,
    MissingCheckpoint,
    UnsavedSceneNotCovered,
    Writer(GateError),
}

/// Only this prepared value may be passed to a future Unity executor. The
/// executor must recheck the revision inside Unity immediately before applying
/// the action; this host-side gate alone cannot close that race.
#[derive(Debug, PartialEq, Eq)]
pub struct PreparedUnityAction {
    request: UnityActionRequest,
    lease_id: LeaseId,
}

impl PreparedUnityAction {
    pub fn request(&self) -> &UnityActionRequest {
        &self.request
    }

    pub fn finish_known(self, gate: &mut UnityMutationGate) -> Result<(), GateError> {
        gate.finish_known(&self.request.target, self.lease_id)
    }

    pub fn outcome_unknown(self, gate: &mut UnityMutationGate) -> Result<(), GateError> {
        gate.mark_outcome_unknown(&self.request.target, self.lease_id)
    }
}

pub fn prepare_unity_action(
    gate: &mut UnityMutationGate,
    snapshot: &UnitySnapshot,
    request: UnityActionRequest,
) -> Result<PreparedUnityAction, ActionGateError> {
    if request.target != snapshot.target {
        return Err(ActionGateError::WrongInstance);
    }
    if snapshot.revision.trim().is_empty()
        || request.expected_revision != snapshot.revision
        || request.checkpoint.revision != snapshot.revision
    {
        return Err(ActionGateError::StaleRevision);
    }
    if request.checkpoint.id.trim().is_empty() {
        return Err(ActionGateError::MissingCheckpoint);
    }
    if !snapshot.dirty_scene_ids.is_empty() && !request.checkpoint.includes_unsaved_scenes {
        return Err(ActionGateError::UnsavedSceneNotCovered);
    }
    let valid = match &request.action {
        UnityAction::CreateGameObject {
            scene_id,
            parent_object_id,
            name,
        } => {
            snapshot.known_scene_ids.contains(scene_id)
                && !name.trim().is_empty()
                && parent_object_id
                    .as_ref()
                    .is_none_or(|id| snapshot.known_object_ids.contains(id))
        }
        UnityAction::SetGameObjectActive {
            scene_id,
            object_id,
            ..
        } => {
            snapshot.known_scene_ids.contains(scene_id)
                && snapshot.known_object_ids.contains(object_id)
        }
    };
    if !valid {
        return Err(ActionGateError::InvalidRequest);
    }
    let lease_id = gate
        .acquire(&request.target)
        .map_err(ActionGateError::Writer)?;
    Ok(PreparedUnityAction { request, lease_id })
}
