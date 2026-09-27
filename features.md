# Feature configuration notes

How to configure specific OpenStack features/backends in a kolla-ansible
deployment: what the **hosts** need before you deploy, and what **settings** turn
the feature on. Add a section here whenever you enable something that needs more
than a one-line `enable_*: true`.

Each entry follows the same shape:

- **Enable** — the `globals.yml` (or override file) settings
- **Host setup** — commands to run before deploying (on the underlying cloud and/or
  the target host)
- **Notes** — limitations, what to check if it fails, how to change later

---

## TLS on the API endpoints

By default, everything talks to OpenStack over plain `http://`. This turns it into
`https://`, so traffic to and from the VIP is encrypted. Two switches, one for each
side:

```yaml
kolla_enable_tls_internal: "yes"    # https:// for internal/service-to-service traffic
kolla_enable_tls_external: "yes"    # https:// for the public/user-facing side
```

With a single, shared VIP for both internal and external traffic, the two settings
are tied together: `kolla_enable_tls_external` defaults to whatever
`kolla_enable_tls_internal` is, and reconfigure refuses to set them differently.
Turn both on. If you use two separate VIPs (below, under Production), you're free
to set them independently — e.g. TLS on the public side only.

**Does Horizon get its own address/certificate?** No, not in a working way. Horizon
uses `kolla_external_fqdn` as its address, same as every other service — e.g. if
that's `cloud.example.com`, Horizon is at `https://cloud.example.com`, with no
separate `horizon.example.com` or dashboard-only setting to configure.

There are technically separate `horizon_external_fqdn` / `horizon_internal_fqdn`
variables you could set to something else, but it wouldn't get Horizon its own
certificate: every service, including Horizon, sits behind the **same** HAProxy
frontend, on the **same** VIP and port, presenting the **one** `haproxy.pem` file.
There's no per-service certificate selection. Setting `horizon_external_fqdn`
separately would just make Horizon *claim* a different address without HAProxy
actually serving a matching certificate for it — so leave it as the default.

**Certificate files**, on the deploy host, under `/etc/kolla/certificates/`:

| File | What it is |
|---|---|
| `haproxy.pem` | The public-facing certificate: certificate + intermediates + private key, all in one PEM file |
| `haproxy-internal.pem` | Same, for the internal side (identical to `haproxy.pem` if you use one shared VIP) |
| `ca/*.crt` | Any CA certificate(s) you want every container to trust |
| `backend-cert.pem`, `backend-key.pem` | Only needed if you also turn on `kolla_enable_tls_backend` |

### Lab / development: a quick, self-signed certificate

kolla-ansible can generate one for you:

```bash
kolla-ansible certificates -i <inventory>
```

This creates a private, self-signed CA (`ca/root.crt`) and a certificate for your
VIP's IP address (`haproxy.pem`), copied to `haproxy-internal.pem` too. kolla-ansible
itself labels this command **"for development only"** — browsers and CLI tools won't
trust it unless you tell them to, which is what the settings below do.

```yaml
kolla_enable_tls_internal: "yes"
kolla_enable_tls_external: "yes"
kolla_copy_ca_into_containers: "yes"    # so OpenStack services trust each other over HTTPS
openstack_cacert: "/etc/ssl/certs/ca-certificates.crt"   # Ubuntu images (Rocky: /etc/pki/tls/certs/ca-bundle.crt)
kolla_admin_openrc_cacert: "/etc/kolla/certificates/ca/root.crt"   # so the `openstack` CLI trusts it too
```

(`openstack_cacert` isn't a file you create — it's just telling containers where
their trust store already lives, so `kolla_copy_ca_into_containers` knows where to
add the lab CA.)

### Production: use a real certificate

The lab approach above is fine to try things out, but a self-signed certificate
isn't trusted by anything outside your own deployment, so production needs real
ones. A few things change:

- **Give the cloud a real domain name**, and usually a separate one for the
  internal/management side vs. the public side, e.g.:
  ```yaml
  kolla_internal_vip_address: "10.0.0.10"                  # management network
  kolla_external_vip_address: "203.0.113.10"                # public-facing network
  kolla_internal_fqdn: "cloud-internal.example.com"
  kolla_external_fqdn: "cloud.example.com"                   # this is what Horizon/users see too
  ```
- **Get a real certificate signed for those names**, instead of running
  `kolla-ansible certificates`. Each certificate needs, as Subject Alternative
  Names (SANs) — this is exactly what `kolla-ansible certificates` puts in its own
  self-signed ones, so it's a good template to follow:
  - a **DNS name** matching the FQDN, e.g. `DNS:cloud.example.com`
  - the **VIP's IP address** too, e.g. `IP:203.0.113.10` — covers anyone who
    connects by IP instead of name
  ```
  haproxy.pem          SAN: DNS:cloud.example.com,          IP:203.0.113.10
  haproxy-internal.pem SAN: DNS:cloud-internal.example.com, IP:10.0.0.10
  ```
  - `haproxy.pem` — a public CA (e.g. Let's Encrypt, or one your organisation
    already trusts)
  - `haproxy-internal.pem` — usually your own internal CA if you have one
  - Only add a file under `ca/` if that certificate came from your **own** private
    CA. A public CA like Let's Encrypt is already trusted everywhere, so nothing
    to add there.
- **Keep the private keys safe** — generate them on the deploy host (or your
  secrets manager) and never copy them elsewhere unnecessarily; file mode `0600`.
- **Optional:** `kolla_enable_tls_backend: "yes"` also encrypts the traffic between
  HAProxy and the services behind it, not just the outward-facing side.

```yaml
kolla_enable_tls_internal: "yes"
kolla_enable_tls_external: "yes"
kolla_enable_tls_backend: "yes"                          # optional
kolla_copy_ca_into_containers: "yes"
openstack_cacert: "/etc/ssl/certs/ca-certificates.crt"    # Ubuntu images (Rocky: /etc/pki/tls/certs/ca-bundle.crt)
kolla_admin_openrc_cacert: "/etc/kolla/certificates/ca/internal-ca.crt"   # only if your internal CA is private
```

### Does this cover *all* internal traffic?

No. `kolla_enable_tls_internal` only covers one specific path: a service calling
another service's **REST API**, which goes through Keystone's catalog and lands on
the shared VIP/HAProxy. Everything below that line is separate, and each needs its
own setting — checked against kolla-ansible's own per-service `_enable_tls`
variables, so this list is exhaustive for what kolla-ansible supports.

**Follows the settings above automatically — nothing extra to do:**
- **Database traffic** (every service → MariaDB, via ProxySQL) follows
  `kolla_enable_tls_internal` / `kolla_enable_tls_backend`, as long as ProxySQL is
  enabled — which it is by default whenever MariaDB is.
- **etcd** (used for coordination/locking) follows `kolla_enable_tls_backend`.

**Needs its own setting, for a genuinely secure production setup:**
- **`kolla_enable_tls_backend: "yes"`** — the HAProxy → service-container hop.
  Without it, `kolla_enable_tls_internal` only encrypts the caller → HAProxy leg;
  the rest of that same REST call, from HAProxy to the actual service, stays plain
  HTTP even with everything above turned on.
- **`rabbitmq_enable_tls: true`** — most of what actually happens between
  services (Nova's scheduler/conductor, Neutron's agents, notifications, etc.) is
  asynchronous RPC over RabbitMQ, not REST calls, so it never touches HAProxy at
  all and isn't covered by anything above. This is the one most worth not
  forgetting. Turning it on also generates its own certificate and switches every
  service to connect over `rabbits://` (port 5671) instead of plain AMQP.
- **`libvirt_tls: true`** — encrypts nova-compute's connection to libvirt on the
  compute nodes. Off by default, and independent of every setting above.

```yaml
rabbitmq_enable_tls: true
libvirt_tls: true
```

**Kolla-ansible has no TLS support for these at all, regardless of settings** — plan
for this separately if it matters for your threat model:
- **Memcached and Valkey** (caching, including Keystone's token cache) — always
  plain text.
- **OVN's own control-plane traffic** (the northbound/southbound databases, and
  chassis ↔ central communication) and **instance consoles** (VNC/noVNC) — also
  always plain text.

### Replacing or renewing a certificate

Drop the new file in at the same path/name as before, then:

```bash
kolla-ansible reconfigure -i <inventory>
```

That's usually all you need. The one exception: if you change **where**
`kolla_admin_openrc_cacert` points (e.g. moving from the lab's `root.crt` to a
production CA file with a different name), also run:

```bash
kolla-ansible post-deploy -i <inventory>
```

so the generated `admin-openrc.sh` picks up the new path.

**Notes:**
- Set a reminder for certificate expiry (e.g. 30 days before) — kolla-ansible
  doesn't renew anything for you automatically, unless you use its optional Let's
  Encrypt integration.
- After moving from the lab's self-signed CA to a real one, anyone with an old
  `clouds.yaml` / `admin-openrc.sh` needs a fresh copy, since it points at the old
  (no longer used) CA file.

---

## Cinder — LVM backend

Gives Cinder somewhere to store volumes, using plain local disk on one node
(`[storage]` in the inventory) shared over iSCSI. **Test only**: every volume depends
on that one node, and there's no replication.

**Enable**:

```yaml
enable_cinder: true
enable_cinder_backend_lvm: true
enable_cinder_backup: false    # the default backup driver is Ceph, which you don't have
#cinder_volume_group: "cinder-volumes"    # set only if you named the volume group differently
```

**Host setup**, before deploying:

1. Get a spare disk (or partition) onto the storage host, however that works for
   your infrastructure:
   - **Bare metal:** a physical disk or an unused partition already in the machine.
   - **VM on a cloud** (including an OpenStack VM): create a volume/disk and attach
     it, e.g. on OpenStack:
     ```bash
     openstack volume create --size 100 <storage-host>-cinder
     openstack server add volume <storage-host> <storage-host>-cinder
     ```
2. On the storage host, turn it into the volume group kolla expects. The name must
   match `cinder_volume_group` (default `cinder-volumes`); prechecks run
   `vgs cinder-volumes` on that host and fail if it's missing:
   ```bash
   lsblk                                  # find the disk from step 1, e.g. /dev/vdb or /dev/sdb
   sudo pvcreate /dev/vdb
   sudo vgcreate cinder-volumes /dev/vdb
   ```
3. Allow iSCSI (**TCP 3260**) from the compute hosts to the storage host, on
   whatever enforces network access between them (firewall, security groups, ...).
   On an OpenStack VM, that's the security group — already covered if they're in
   the same one with the default "allow all within group" rule:
   ```bash
   openstack security group rule create --ingress --protocol tcp --dst-port 3260 \
     --remote-group <sg> <sg>
   ```

**How it works:** `tgtd` runs on the `[storage]` hosts and shares each volume over
iSCSI; `iscsid` runs on the computes (and the storage host) and connects to it, so
each volume appears to Nova as a local disk on whichever compute node is using it.

**Notes:**
- Only needed if you actually attach volumes to instances. Without it, Cinder has no
  backend and prechecks fail with "Please enable at least one backend when enabling
  Cinder" — if you don't need volumes, set `enable_cinder: false` instead.
- If you add more backends later (Ceph, NFS, ...), create a volume type per backend
  so users can choose:
  ```bash
  openstack volume type create --property volume_backend_name=lvm-1 lvm
  ```
- For production, use a real shared backend (Ceph, or a supported storage array)
  instead — `cinder_backend_ceph: true`.

---

## Octavia — load balancer providers

Octavia has two ways to actually build a load balancer, and you can enable either
or both together (users then pick with `--provider` when creating one):

- **OVN provider** — turns your existing OVN networking into a load balancer.
  No extra VMs, no certificates, nothing extra to build. **Limited to TCP/UDP** —
  no TLS termination, no HTTP-level rules (host/path-based routing, etc.).
- **Amphora provider** (Octavia's own default) — spins up a small VM per load
  balancer to run it. Full-featured (HTTP/L7 rules, TLS termination), but needs
  certificates, a management network, an uploaded VM image, and Valkey.

If TCP/UDP load balancing is all you need, OVN alone is much less to set up and
maintain.

### OVN provider

**Enable:**

```yaml
enable_octavia: true
octavia_provider_drivers: "ovn:OVN provider"
octavia_provider_agents: "ovn"
```

**Host setup:** none — no certificates, VM image, management network or Valkey
needed.

### Amphora provider

**Enable**, in addition to (or instead of) OVN:

```yaml
enable_octavia: true
octavia_provider_drivers: "amphora:Amphora provider, ovn:OVN provider"   # or just amphora, if you don't want OVN too
enable_valkey: true    # required whenever "amphora" is in octavia_provider_drivers
```

**1. Certificates** — Octavia's controllers and the amphora VMs authenticate to
each other over TLS, so this needs its own certificates (separate from the
API-endpoint TLS above):

```bash
kolla-ansible octavia-certificates -i <inventory>
```

Fine for a lab. Generates everything under `/etc/kolla/config/octavia/`, using
placeholder issuer details you can override first if you want:

```yaml
octavia_certs_country: US
octavia_certs_state: Oregon
octavia_certs_organization: OpenStack
```

**For production**, generate them yourself following
[Octavia's own certificate guide](https://docs.openstack.org/octavia/latest/admin/guides/certificates.html)
instead, and copy the four files in:

```bash
cp client_ca/certs/ca.cert.pem       /etc/kolla/config/octavia/client_ca.cert.pem
cp server_ca/certs/ca.cert.pem       /etc/kolla/config/octavia/server_ca.cert.pem
cp server_ca/private/ca.key.pem      /etc/kolla/config/octavia/server_ca.key.pem
cp client_ca/private/client.cert-and-key.pem /etc/kolla/config/octavia/client.cert-and-key.pem
```

Either way, check expiry later with `kolla-ansible octavia-certificates --check-expiry <days>`.

**2. A network the amphora VMs can be reached on** — the Octavia workers need to
talk to each amphora VM, so this needs a real network route, not just something
Neutron knows about:

- **Lab / testing only:**
  ```yaml
  octavia_network_type: "tenant"
  ```
  kolla-ansible creates a private tenant network for this automatically — quickest
  option, but upstream's own docs say not to use it in production ("the network
  may not be reliable enough").
- **Production (the default, `octavia_network_type: "provider"`):** needs a real
  VLAN (or flat) network that's actually wired up outside OpenStack too — i.e. your
  physical switches need that VLAN, and it must reach the controllers' NICs:
  ```yaml
  enable_neutron_provider_networks: true   # if using a VLAN
  octavia_network_interface: "<NIC on the controllers on that network>"
  octavia_amp_network:
    name: lb-mgmt-net
    provider_network_type: vlan
    provider_segmentation_id: 1000
    provider_physical_network: physnet1
    subnet:
      name: lb-mgmt-subnet
      cidr: "10.1.2.0/24"
      allocation_pool_start: "10.1.2.100"
      allocation_pool_end: "10.1.2.200"
      gateway_ip: "10.1.2.1"
  ```
  With `octavia_auto_configure: true` (the default whenever `amphora` is listed),
  kolla-ansible creates this network/subnet, the `amphora` flavor, an SSH keypair
  and the security groups for you from these settings — no manual `openstack`
  commands needed. Only fall back to `octavia_auto_configure: false` (registering
  each resource by hand, then feeding kolla-ansible their IDs) if you need more
  control than the settings above allow; see the
  [Octavia networking guide](https://docs.openstack.org/kolla-ansible/2026.1/reference/networking/octavia.html)
  for that path.

**3. An amphora VM image** — every amphora load balancer boots from an OpenStack
image tagged `amphora` (matches `octavia_amp_image_tag`). Build it from the
matching Octavia branch:

```bash
git clone https://opendev.org/openstack/octavia -b stable/2026.1
python3 -m venv dib-venv && source dib-venv/bin/activate
pip install diskimage-builder
cd octavia/diskimage-create && ./diskimage-create.sh

source /etc/kolla/octavia-openrc.sh   # needs `kolla-ansible post-deploy` run first
openstack image create amphora-x64-haproxy.qcow2 --container-format bare \
  --disk-format qcow2 --private --tag amphora --file amphora-x64-haproxy.qcow2 \
  --property hw_architecture='x86_64' --property hw_rng_model=virtio
```

**Notes:**
- **Production redundancy:** the default `octavia_loadbalancer_topology: "SINGLE"`
  means one amphora VM per load balancer — a single point of failure for that load
  balancer. Set `octavia_loadbalancer_topology: "ACTIVE_STANDBY"` for production;
  it runs two amphorae per load balancer (roughly double the VM capacity needed).
- **Debugging:** `ssh -i /etc/kolla/octavia-worker/octavia_ssh_key ubuntu@<amphora-ip>`
  from an `octavia-worker` host.
- Deploying just changes to Octavia settings can be scoped with
  `kolla-ansible deploy -i <inventory> --tags common,horizon,octavia`, instead of a
  full redeploy.
