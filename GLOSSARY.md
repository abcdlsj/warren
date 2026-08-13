# Warren Terminal Workspace

Warren keeps durable terminal runtimes separate from the client views used to access them.

## Language

**Workspace**:
A named working-directory context belonging to a Project, in which Warren
Terminal Sessions run. The project's main checkout is represented as the root
Workspace; linked Git worktrees are additional Workspaces. A Workspace has a
stable identity, an editable display name, a filesystem path, and a checked-out
Git branch. The display name and branch name are independent fields.

**Project**:
The identity of one Git repository rooted at its main checkout. A Project owns
the repository identity and the set of Git Workspaces derived from that
repository. It is metadata about the repository, not a terminal runtime.

**Warren Terminal Session**:
A Host-owned terminal runtime represented by one client Tab in Warren v1. The
Session is backed by one tmux runtime session. Closing its Tab terminates the
runtime and ends the Warren Terminal Session; it is not a background runtime.

**Agent Session ID**:
An identifier assigned by an external agent CLI such as Codex or Claude Code.
Warren may persist this identifier as metadata for future explicit resume, but
does not automatically resume the agent conversation.

**Tab**:
A client-local entry that opens exactly one Warren Terminal Session in one
window. In Warren v1, closing a Tab is also the explicit termination action for
its Warren Terminal Session. A future multi-client sharing model may revise
this rule.

**Workspace display name**:
The user-editable label shown for a Workspace. Renaming it does not rename or
checkout a Git branch and does not change the Workspace path.

**Git branch**:
The branch checked out in a Workspace's working directory. It is managed by
Git and is not changed when the Workspace display name is edited.

**Terminal display title**:
The contextual label above a terminal, rendered from a Title Template and the Session's current metadata. It does not rename the Session or Tab.
_Avoid_: Session title, Tab title

**Title Template**:
A client preference containing placeholders for Session and runtime metadata. Warren clients share its placeholder language, while each client may keep its own preferred value.
