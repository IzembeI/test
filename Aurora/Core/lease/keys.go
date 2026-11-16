package lease

// Trusted public keys (base64url, raw Ed25519), made by `aurora-license
// keygen`. The private halves never enter the repository: the server key is
// a Cloudflare Worker secret, the admin key stays in the owner's keys folder.
const (
	// ServerPublicKey verifies online leases issued by the license Worker.
	ServerPublicKey = "MaW0T4XATGWz1dvPhE2ykZe5_PavK-y4Yyc-FuZ3Q1w"
	// AdminPublicKey verifies offline leases signed with `aurora-license sign`.
	AdminPublicKey = "HgEkA0D7E2dKlyCLYziUsodWGz8seb3BQaSi_COGQvo"
)
