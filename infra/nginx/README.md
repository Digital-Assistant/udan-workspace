# nginx

Local reverse proxy and static host. It listens on ports 80 and 443 and serves the dev TLS certificate from
`infra/nginx/localhost/` (mounted read-only at `/etc/nginx/certs/`). `scripts/infra-certs.sh` creates the certificate.

## Files

| File | Purpose |
|---|---|
| `conf.d/localhost.conf` | Port 80 redirects to HTTPS. Port 443 serves a plain landing page for `udan-sdk.nistapp` and `localhost`. |
| `conf.d/cache.conf` | Gzip, buffers and cache settings (http level). |
| `conf.d/temp-paths.conf` | Temp paths under `/tmp`, so the container needs no other writable path. |
| `conf.d/extra/` | Optional extra server blocks. |

## Host names

`udan-sdk.nistapp` is a local development name only. It has no public DNS. Add it to `/etc/hosts` pointing at
`127.0.0.1` if you want to use it. `localhost` works without any change.

## Extra server blocks

Other repositories can drop whole `server { ... }` files into `conf.d/extra/` (`*.conf`). `localhost.conf` ends with
`include /etc/nginx/conf.d/extra/*.conf;`. The image includes `conf.d/*.conf` at http level, and `extra/` is one level
deeper, so the image does not pick it up itself; this explicit include does. The folder may stay empty: nginx accepts a
wildcard include that matches nothing. Everything in `extra/` except `.gitkeep` is ignored by git.

The SDK host has no static content of its own here. A repository that needs to serve files mounts them into the
container (for example through a compose override) and adds a server block in `extra/`.
