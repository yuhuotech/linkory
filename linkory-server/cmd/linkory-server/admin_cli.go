package main

import (
	"bufio"
	"context"
	"database/sql"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/linkory/linkory-server/internal/admin"
	"golang.org/x/term"
)

// padCell pads to a terminal column width; CJK characters take two columns, which fmt's %-Ns does not know.
func padCell(s string, width int) string {
	w := 0
	for _, r := range s {
		if r >= 0x1100 && (r <= 0x115f || (r >= 0x2e80 && r <= 0xa4cf) || (r >= 0xac00 && r <= 0xd7a3) || (r >= 0xf900 && r <= 0xfaff) || (r >= 0xfe30 && r <= 0xfe6f) || (r >= 0xff00 && r <= 0xff60) || (r >= 0xffe0 && r <= 0xffe6)) {
			w += 2
		} else {
			w++
		}
	}
	if w >= width {
		return s + " "
	}
	return s + strings.Repeat(" ", width-w)
}

// readPassword asks twice on a terminal (no echo); piped input takes two lines, for controlled automation.
func readPassword() (string, error) {
	var pw, confirm string
	if term.IsTerminal(int(os.Stdin.Fd())) {
		fmt.Fprint(os.Stderr, "管理密码（至少 12 字符）：")
		b, e := term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Fprintln(os.Stderr)
		if e != nil {
			return "", e
		}
		pw = string(b)
		fmt.Fprint(os.Stderr, "再次输入：")
		b, e = term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Fprintln(os.Stderr)
		if e != nil {
			return "", e
		}
		confirm = string(b)
	} else {
		scan := bufio.NewScanner(os.Stdin)
		if scan.Scan() {
			pw = scan.Text()
		}
		if scan.Scan() {
			confirm = scan.Text()
		}
		if e := scan.Err(); e != nil {
			return "", e
		}
	}
	if pw != confirm {
		return "", fmt.Errorf("两次密码不一致")
	}
	return pw, nil
}

func adminCLI(db *sql.DB, args []string) error {
	const usage = "用法：admin create|disable|passwd|list [--username 名称] [--role admin|readonly]"
	if len(args) == 0 {
		return fmt.Errorf(usage)
	}
	f := flag.NewFlagSet("admin", flag.ContinueOnError)
	name := f.String("username", "", "管理员账号")
	role := f.String("role", "admin", "admin 或 readonly")
	if e := f.Parse(args[1:]); e != nil {
		return e
	}
	svc := admin.NewService(db, nil, 30)
	ctx := context.Background()
	user := strings.TrimSpace(*name)
	switch args[0] {
	case "create":
		pw, e := readPassword()
		if e != nil {
			return e
		}
		if e := svc.CreateAccount(ctx, user, pw, *role); e != nil {
			return e
		}
		fmt.Println("管理员已创建（不关联任何用户设备）")
	case "disable":
		if e := svc.DisableAccount(ctx, user); e != nil {
			return e
		}
		fmt.Println("管理员已禁用并撤销会话")
	case "passwd":
		if user == "" {
			return fmt.Errorf("请用 --username 指定管理员")
		}
		pw, e := readPassword()
		if e != nil {
			return e
		}
		if e := svc.ResetPassword(ctx, user, pw); e != nil {
			return e
		}
		fmt.Println("密码已重置，该管理员的全部会话已失效")
	case "list":
		accounts, e := svc.ListAccounts(ctx)
		if e != nil {
			return e
		}
		for _, a := range accounts {
			state := "启用"
			if a.Disabled {
				state = "已禁用"
			}
			fmt.Println(padCell(a.Username, 24) + padCell(a.Role, 10) + padCell(state, 8) + a.CreatedAt.UTC().Format("2006-01-02 15:04"))
		}
	default:
		return fmt.Errorf(usage)
	}
	return nil
}
