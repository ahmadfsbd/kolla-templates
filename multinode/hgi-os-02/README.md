# hgi-os-02

A second, independent Kolla-Ansible 2026.1 cluster (Ubuntu images, ML2/OVN, TLS) driven from the
same deployment host as hgi-os-01. `os-02-ctl-01` (10.11.11.91) is control, network, storage and
monitoring; `os-02-cmp-01` (10.11.11.60) is the compute. API and Horizon: `https://10.11.11.39`
(keepalived router ID 52; hgi-os-01 uses 51).

## Its own config dir: `/etc/kolla-02`

Both clusters are deployed from one host, so this one keeps everything in `/etc/kolla-02`. Pass
`--configdir /etc/kolla-02` to **every** `kolla-ansible` command; without it kolla-ansible reads and
overwrites hgi-os-01's `/etc/kolla`.

## Where things are (on the deployment host; paths only, never copy the contents anywhere)

| What | Path |
|---|---|
| Venv | `~/kolla-venv-2026.1-02` |
| Inventory and overrides | this folder: `multinode`, `globals-override.yml`, `etc-kolla-config/`, `nexus-federation.yml` |
| Kolla config dir | `/etc/kolla-02` (`globals.yml`, `globals.d/`, `config/`) |
| Admin credentials | `/etc/kolla-02/admin-openrc.sh`, `/etc/kolla-02/admin-openrc-system.sh`, `/etc/kolla-02/clouds.yaml` (clouds `kolla-admin`, `kolla-admin-system`, `kolla-admin-internal`, `kolla-admin-system-internal`) |
| Other openrc files | `/etc/kolla-02/public-openrc.sh`, `public-openrc-system.sh`, `octavia-openrc.sh` |
| Service passwords | `/etc/kolla-02/passwords.yml` (generated for this cluster) |
| CA (for `OS_CACERT` and clients) | `/etc/kolla-02/certificates/ca/root.crt` |
| SSH to the nodes | `ubuntu@<node>` with `~/.ssh/id_rsa` |

## Use it

```bash
cd ~/temp/kolla-templates/multinode/hgi-os-02
source ~/kolla-venv-2026.1-02/bin/activate
source /etc/kolla-02/admin-openrc.sh         # in a shell without hgi-os-01's OS_* variables
openstack endpoint list
kolla-ansible reconfigure -i multinode --configdir /etc/kolla-02 --tags <service>

# or without sourcing anything
OS_CLIENT_CONFIG_FILE=/etc/kolla-02/clouds.yaml openstack --os-cloud kolla-admin endpoint list
```

## Still to do (2026-10-05)

- ~~**Own CA.**~~ Done 2026-10-05: its own root CA and endpoint certificate
  (`kolla-ansible certificates --configdir /etc/kolla-02`, then a full `reconfigure`). The copies
  of hgi-os-01's CA files it started with were deleted the same day.
- **Federation files.** `/etc/kolla-02/globals.d/nexus-federation.yml` still points at
  `/etc/kolla/config/keystone/federation/…` (hgi-os-01's mapping and OIDC client). This cluster
  needs its own Keycloak client (`keystone-hgi-os-02`), mapping and metadata, written into
  `/etc/kolla-02/config/keystone/`, and the two paths changed to `/etc/kolla-02`.
  Do not just delete `nexus-federation.yml`: Kolla then leaves `keystone_httpd` holding port
  5000 and the `keystone` container crash-loops (API 503). Replace the files, or remove
  `keystone_httpd` before the reconfigure.
- **Networks, flavors, images.** None exist yet.
