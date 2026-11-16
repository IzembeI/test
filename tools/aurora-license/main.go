// Command aurora-license is the owner's tool for Aurora licenses: it makes
// the signing keys, signs offline leases for single phones and manages
// activation keys on the license Worker.
//
// Keys live in %APPDATA%\aurora (or $AURORA_KEYS_DIR), never in the repo.
package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/werx/aurora/corebridge/lease"
)

const usage = `aurora-license — лицензии Aurora

Ключи подписи (папка: %APPDATA%\aurora или $AURORA_KEYS_DIR):
  keygen [-force]                 создать ключи admin и server, токен администратора
  pub                             показать открытые ключи
  secret                          вывести SERVER_PRIVATE_KEY для Worker (только в канал/пайп!)

Офлайн-лицензия для одного телефона (подписывается ключом admin):
  sign -kc ID [-ifv ID] [-days 30]

Ключи активации на сервере ($AURORA_LICENSE_URL, $AURORA_ADMIN_TOKEN или файл admin.token):
  issue [-n 10] [-days 365]       выпустить ключи (показываются один раз)
  reset KEY|SUB                   отвязать ключ от телефона
  revoke KEY|SUB                  отозвать ключ
  list                            список ключей
  check KEY                       проверить формат ключа (без сети)
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	var err error
	args := os.Args[2:]
	switch os.Args[1] {
	case "keygen":
		err = cmdKeygen(args)
	case "pub":
		err = cmdPub()
	case "secret":
		err = cmdSecret()
	case "sign":
		err = cmdSign(args)
	case "issue":
		err = cmdIssue(args)
	case "reset", "revoke":
		err = cmdKeyAction(os.Args[1], args)
	case "list":
		err = cmdList()
	case "check":
		err = cmdCheck(args)
	case "help", "-h", "--help":
		fmt.Print(usage)
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "ошибка:", err)
		os.Exit(1)
	}
}

// keysDir is where private keys are kept.
func keysDir() (string, error) {
	if d := os.Getenv("AURORA_KEYS_DIR"); d != "" {
		return filepath.Abs(d)
	}
	base, err := os.UserConfigDir() // %APPDATA% on Windows
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "aurora"), nil
}

// insideGitRepo reports whether dir is inside a git working tree, where a
// private key could be committed by accident.
func insideGitRepo(dir string) bool {
	for d := dir; ; {
		if _, err := os.Stat(filepath.Join(d, ".git")); err == nil {
			return true
		}
		parent := filepath.Dir(d)
		if parent == d {
			return false
		}
		d = parent
	}
}

func cmdKeygen(args []string) error {
	fs := flag.NewFlagSet("keygen", flag.ExitOnError)
	force := fs.Bool("force", false, "перезаписать существующие ключи (старые лицензии перестанут работать!)")
	fs.Parse(args)
	dir, err := keysDir()
	if err != nil {
		return err
	}
	if insideGitRepo(dir) {
		return fmt.Errorf("папка %s внутри git-репозитория — ключи туда класть нельзя; задайте AURORA_KEYS_DIR вне репозитория", dir)
	}
	if !*force {
		for _, n := range []string{"admin.key", "server.key"} {
			if _, err := os.Stat(filepath.Join(dir, n)); err == nil {
				return fmt.Errorf("ключи уже есть в %s; -force создаст новые, и все выданные лицензии станут недействительны", dir)
			}
		}
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	pubs := map[string]string{}
	for _, kid := range []string{lease.KidAdmin, lease.KidServer} {
		pub, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return err
		}
		text, err := lease.EncodePrivate(priv)
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dir, kid+".key"), []byte(text+"\n"), 0o600); err != nil {
			return err
		}
		pubs[kid] = lease.EncodePublic(pub)
		if err := os.WriteFile(filepath.Join(dir, kid+".pub"), []byte(pubs[kid]+"\n"), 0o644); err != nil {
			return err
		}
	}
	tok := make([]byte, 32)
	if _, err := rand.Read(tok); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "admin.token"), []byte(base64.RawURLEncoding.EncodeToString(tok)+"\n"), 0o600); err != nil {
		return err
	}
	fmt.Println("Ключи записаны в", dir)
	fmt.Println()
	fmt.Println("Открытые ключи — вставьте в Aurora/Core/lease/keys.go:")
	fmt.Printf("  ServerPublicKey = %q\n", pubs[lease.KidServer])
	fmt.Printf("  AdminPublicKey  = %q\n", pubs[lease.KidAdmin])
	fmt.Println("и в license-worker/wrangler.toml: SERVER_PUBLIC_KEY =", pubs[lease.KidServer])
	fmt.Println()
	fmt.Println("Секреты Worker (не сохраняйте их в репозитории):")
	fmt.Println("  SERVER_PRIVATE_KEY: aurora-license secret | npx wrangler secret put SERVER_PRIVATE_KEY")
	fmt.Println("  ADMIN_TOKEN:        содержимое файла", filepath.Join(dir, "admin.token"))
	return nil
}

func readKeyFile(name string) (string, error) {
	dir, err := keysDir()
	if err != nil {
		return "", err
	}
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		return "", fmt.Errorf("нет файла %s (сначала aurora-license keygen): %w", filepath.Join(dir, name), err)
	}
	return strings.TrimSpace(string(b)), nil
}

func cmdPub() error {
	for _, kid := range []string{lease.KidServer, lease.KidAdmin} {
		p, err := readKeyFile(kid + ".pub")
		if err != nil {
			return err
		}
		fmt.Printf("%s: %s\n", kid, p)
	}
	return nil
}

// cmdSecret prints the server private key exactly as the Worker secret
// SERVER_PRIVATE_KEY expects it (base64 PKCS#8), meant for a pipe.
func cmdSecret() error {
	s, err := readKeyFile("server.key")
	if err != nil {
		return err
	}
	if _, err := lease.DecodePrivate(s); err != nil {
		return err
	}
	fmt.Println(s)
	return nil
}

func cmdSign(args []string) error {
	fs := flag.NewFlagSet("sign", flag.ExitOnError)
	kc := fs.String("kc", "", "ID устройства (Keychain), из экрана «Лицензия»")
	ifv := fs.String("ifv", "", "identifierForVendor (необязательно)")
	days := fs.Int("days", 30, "срок, дней")
	fs.Parse(args)
	if strings.TrimSpace(*kc) == "" && strings.TrimSpace(*ifv) == "" {
		return errors.New("нужен -kc (или -ifv)")
	}
	if *days <= 0 {
		return errors.New("-days должен быть больше 0")
	}
	text, err := readKeyFile("admin.key")
	if err != nil {
		return err
	}
	priv, err := lease.DecodePrivate(text)
	if err != nil {
		return err
	}
	tok, err := signOffline(priv, strings.TrimSpace(*kc), strings.TrimSpace(*ifv), *days, time.Now())
	if err != nil {
		return err
	}
	fmt.Println(tok)
	return nil
}

func signOffline(priv ed25519.PrivateKey, kc, ifv string, days int, now time.Time) (string, error) {
	t := now.Unix()
	return lease.Sign(lease.Claims{
		Kid: lease.KidAdmin, Sub: lease.SubOffline, KC: kc, IFV: ifv,
		Iat: t, Exp: t + int64(days)*86400, St: t,
	}, priv)
}

func cmdCheck(args []string) error {
	if len(args) != 1 {
		return errors.New("использование: check KEY")
	}
	k, ok := lease.NormalizeKey(args[0])
	if !ok {
		return errors.New("ключ введён с ошибкой (формат или контрольная сумма)")
	}
	fmt.Println(k, "— формат верный, sub", lease.KeySub(k))
	return nil
}

// MARK: Worker admin API

type client struct {
	base  string
	token string
	http  *http.Client
}

func newClient() (*client, error) {
	base := strings.TrimRight(strings.TrimSpace(os.Getenv("AURORA_LICENSE_URL")), "/")
	if base == "" {
		return nil, errors.New("задайте AURORA_LICENSE_URL (адрес Worker, например https://aurora-license.<account>.workers.dev)")
	}
	tok := strings.TrimSpace(os.Getenv("AURORA_ADMIN_TOKEN"))
	if tok == "" {
		t, err := readKeyFile("admin.token")
		if err != nil {
			return nil, errors.New("задайте AURORA_ADMIN_TOKEN или создайте ключи (keygen)")
		}
		tok = t
	}
	return &client{base: base, token: tok, http: &http.Client{Timeout: 30 * time.Second}}, nil
}

func (c *client) call(method, path string, body any, out any) error {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, c.base+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if resp.StatusCode/100 != 2 {
		var e struct {
			Error string `json:"error"`
		}
		if json.Unmarshal(data, &e) == nil && e.Error != "" {
			return fmt.Errorf("сервер %d: %s", resp.StatusCode, e.Error)
		}
		return fmt.Errorf("сервер %d: %s", resp.StatusCode, strings.TrimSpace(string(data)))
	}
	if out != nil {
		return json.Unmarshal(data, out)
	}
	return nil
}

func cmdIssue(args []string) error {
	fs := flag.NewFlagSet("issue", flag.ExitOnError)
	n := fs.Int("n", 10, "сколько ключей")
	days := fs.Int("days", 365, "срок действия с первой активации, дней (0 — бессрочно)")
	fs.Parse(args)
	c, err := newClient()
	if err != nil {
		return err
	}
	var out struct {
		Keys []string `json:"keys"`
		Days int      `json:"days"`
	}
	if err := c.call("POST", "/admin/issue", map[string]int{"n": *n, "days": *days}, &out); err != nil {
		return err
	}
	for _, k := range out.Keys {
		fmt.Println(k)
	}
	fmt.Fprintf(os.Stderr, "Выпущено %d ключей, срок %d дн. с активации. Сохраните их: сервер хранит только хэши.\n", len(out.Keys), out.Days)
	return nil
}

// keyRef turns a key or an 8-hex sub (as shown by list) into the request body.
func keyRef(s string) (map[string]string, error) {
	s = strings.TrimSpace(s)
	if k, ok := lease.NormalizeKey(s); ok {
		return map[string]string{"key": k}, nil
	}
	if len(s) == 8 && strings.Trim(strings.ToLower(s), "0123456789abcdef") == "" {
		return map[string]string{"sub": strings.ToLower(s)}, nil
	}
	return nil, errors.New("нужен ключ AUR-… или 8-значный sub из list")
}

func cmdKeyAction(action string, args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("использование: %s KEY|SUB", action)
	}
	body, err := keyRef(args[0])
	if err != nil {
		return err
	}
	c, err := newClient()
	if err != nil {
		return err
	}
	var out map[string]any
	if err := c.call("POST", "/admin/"+action, body, &out); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(out, "", "  ")
	fmt.Println(string(b))
	return nil
}

func cmdList() error {
	c, err := newClient()
	if err != nil {
		return err
	}
	var out struct {
		Keys []struct {
			Sub       string `json:"sub"`
			Status    string `json:"status"`
			KC        string `json:"kc"`
			IFV       string `json:"ifv"`
			Until     int64  `json:"until"`
			Days      int    `json:"days"`
			Rebinds   int    `json:"rebinds"`
			Created   int64  `json:"created"`
			Activated int64  `json:"activated"`
		} `json:"keys"`
	}
	if err := c.call("GET", "/admin/list", nil, &out); err != nil {
		return err
	}
	date := func(t int64) string {
		if t == 0 {
			return "—"
		}
		return time.Unix(t, 0).Format("02.01.2006")
	}
	fmt.Printf("%-8s  %-8s  %-10s  %-10s  %-10s  %-10s  %s\n", "SUB", "СТАТУС", "ВЫПУЩЕН", "АКТИВИРОВАН", "ДО", "УСТРОЙСТВО", "СБРОСОВ")
	for _, k := range out.Keys {
		dev := "—"
		if k.KC != "" {
			dev = k.KC
		}
		until := date(k.Until)
		if k.Until == 0 && k.Days == 0 {
			until = "бессрочно"
		} else if k.Until == 0 {
			until = fmt.Sprintf("%d дн.", k.Days)
		}
		fmt.Printf("%-8s  %-8s  %-10s  %-11s  %-10s  %-10s  %d\n", k.Sub, k.Status, date(k.Created), date(k.Activated), until, dev, k.Rebinds)
	}
	fmt.Fprintf(os.Stderr, "Всего: %d\n", len(out.Keys))
	return nil
}
