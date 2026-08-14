package api

import "time"

const Version = "1.0"

type Host struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	User    string `json:"user,omitempty"`
	OS      string `json:"os,omitempty"`
	Version string `json:"version"`
}

type Project struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Path      string    `json:"path"`
	CreatedAt time.Time `json:"createdAt"`
}

type Workspace struct {
	ID        string    `json:"id"`
	ProjectID string    `json:"project"`
	Name      string    `json:"name"`
	Path      string    `json:"path"`
	Branch    string    `json:"branch,omitempty"`
	Kind      string    `json:"kind"`
	CreatedAt time.Time `json:"createdAt"`
}

type Session struct {
	ID          string     `json:"id"`
	WorkspaceID string     `json:"workspace"`
	Title       string     `json:"title"`
	Kind        string     `json:"kind"`
	Command     string     `json:"command,omitempty"`
	Runtime     string     `json:"runtime"`
	Lifecycle   string     `json:"lifecycle"`
	Epoch       uint64     `json:"epoch,omitempty"`
	Sequence    uint64     `json:"sequence,omitempty"`
	CreatedAt   time.Time  `json:"createdAt"`
	EndedAt     *time.Time `json:"endedAt,omitempty"`
}

type State struct {
	Schema     int         `json:"schema"`
	Host       Host        `json:"host"`
	Projects   []Project   `json:"projects"`
	Workspaces []Workspace `json:"workspaces"`
	Sessions   []Session   `json:"sessions"`
}

type Envelope struct {
	Type      string         `json:"t"`
	ID        string         `json:"id,omitempty"`
	Token     string         `json:"token,omitempty"`
	Version   string         `json:"version,omitempty"`
	Method    string         `json:"method,omitempty"`
	Params    map[string]any `json:"params,omitempty"`
	Session   string         `json:"session,omitempty"`
	Workspace string         `json:"workspace,omitempty"`
	Project   string         `json:"project,omitempty"`
	Command   string         `json:"command,omitempty"`
	Kind      string         `json:"kind,omitempty"`
	Title     string         `json:"title,omitempty"`
	Data      string         `json:"data,omitempty"`
	Cols      int            `json:"cols,omitempty"`
	Rows      int            `json:"rows,omitempty"`
	Epoch     uint64         `json:"epoch,omitempty"`
	Sequence  uint64         `json:"sequence,omitempty"`
}

type Response struct {
	Type   string `json:"t"`
	ID     string `json:"id,omitempty"`
	OK     bool   `json:"ok"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}
