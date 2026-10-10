// Package audit stores management events without credentials or user content.
package audit

import (
	"context"
	"database/sql"
)

type Executor interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}
type Event struct {
	ActorID                                   any
	Actor, Action, Target, Reason, Result, IP string
}

func Write(ctx context.Context, db Executor, e Event) error {
	_, err := db.ExecContext(ctx, `INSERT INTO admin_audit(actor_id,actor,action,target,reason,result,source_ip) VALUES(?,?,?,?,?,?,?)`, e.ActorID, e.Actor, e.Action, e.Target, e.Reason, e.Result, e.IP)
	return err
}
