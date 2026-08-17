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

**Terminal Group**:
A Host-owned ordered container for standalone terminal sessions that are not
bound to a Project or Workspace. The first Group is the default destination
for newly created standalone sessions. A Group may define a default startup
directory; when it does not, the Host user's home directory is used.

**Session Scope**:
The single ownership context of a Warren Terminal Session. A scope is either a
Workspace or a Terminal Group. A Session never belongs to both contexts and
never exists without one.

**Warren Terminal Session**:
A Host-owned terminal execution resource belonging to one Session Scope. It has
a durable lifecycle independent of client connectivity; in Warren v1, closing
its Tab is the user's command to end it.
_Avoid_: Session

**Runtime Binding**:
The opaque association between a Warren Terminal Session and its runtime
backend. It is recovery metadata, not a second terminal resource.

**Runtime Session**:
The process container owned by a runtime adapter — a ghostline PTY by default,
or a tmux session for the alternative runtime — bound one-to-one to a Warren
Terminal Session. It is an implementation of the runtime boundary, not
Warren's durable Session identity.
_Avoid_: Session

**Agent Conversation**:
A conversation owned by an external agent CLI such as Codex or Claude Code.
Warren may retain its external identifier and observed activity, but does not
own its lifecycle or equate it with a Warren Terminal Session.
_Avoid_: Codex Session, Claude Session

**Agent Activity**:
The currently observed work state of an external Agent Conversation. It is
optional and does not represent terminal lifecycle or client connectivity.

**Tab**:
A device-local window entry that references one Warren Terminal Session within a
Workspace View or Terminal Group View. It does not own Host state, although
Close Tab is the Warren v1 command for ending the referenced Session and
removing the entry.

**Attachment**:
A temporary client connection to a Warren Terminal Session. Disconnecting an
Attachment does not end the Session or its runtime.

**Workspace display name**:
The user-editable label shown for a Workspace. Renaming it does not rename or
checkout a Git branch and does not change the Workspace path.

**Git branch**:
The branch checked out in a Workspace's working directory. It is managed by
Git and is not changed when the Workspace display name is edited.

**Terminal display title**:
The contextual label above a terminal, rendered from a Title Template and the
Warren Terminal Session's current metadata. It does not rename the Warren
Terminal Session or Tab.
_Avoid_: Session title, Tab title

**Title Template**:
A client preference containing placeholders for Warren Terminal Session and
runtime metadata. Warren clients share its placeholder language, while each
client may keep its own preferred value.
