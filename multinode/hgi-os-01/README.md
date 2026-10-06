# hgi-os-01

Kolla-Ansible 2026.1, Ubuntu images, ML2/OVN with TLS. `os-ctl-01` is control, network, storage
and monitoring; `os-cmp-01` and `os-cmp-02` are computes. API and Horizon: `https://10.11.11.102`.

## Where things are (on the deployment host; paths only, never copy the contents anywhere)

| What | Path |
|---|---|
| Venv | `~/kolla-venv-2026.1` |
| Inventory and overrides | this folder: `multinode`, `globals-override.yml`, `etc-kolla-config/`, `nexus-federation.yml` |
| Kolla config dir | `/etc/kolla` (the default, so no `--configdir`) |
| Admin credentials | `/etc/kolla/admin-openrc.sh`, `/etc/kolla/admin-openrc-system.sh`, `/etc/kolla/clouds.yaml` (clouds `kolla-admin`, `kolla-admin-system`, `kolla-admin-internal`, `kolla-admin-system-internal`) |
| Other openrc files | `/etc/kolla/public-openrc.sh`, `public-openrc-system.sh`, `octavia-openrc.sh` |
| Service passwords | `/etc/kolla/passwords.yml` |
| CA (for `OS_CACERT` and clients) | `/etc/kolla/certificates/ca/root.crt` |
| SSH to the nodes | `ubuntu@<node>` with `~/.ssh/ma30_key` |

## Use it

```bash
cd ~/temp/kolla-templates/multinode/hgi-os-01
source ~/kolla-venv-2026.1/bin/activate
source /etc/kolla/admin-openrc.sh            # never source two clouds' openrc in one shell
openstack endpoint list
kolla-ansible reconfigure -i multinode --tags <service>
```

The same cloud names exist in hgi-os-02's `clouds.yaml`; select the file as well as the name.
