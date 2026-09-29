# Troubleshooting and operations

Where things live on a kolla-ansible node, how a service gets its config, and the
commands for finding out what's wrong. Paths and names are from kolla-ansible 2026.1
with Docker. With Podman, replace `docker` with `podman`.

---

## How a node is laid out

Every OpenStack service runs as a container, and so do the services they depend on:
MariaDB, RabbitMQ, HAProxy, keepalived, Open vSwitch / OVN and libvirt. Each node only
runs the containers for its inventory groups, so a controller has far more than a
compute node.

| What | Where on the node | Notes |
|---|---|---|
| Generated service config | `/etc/kolla/<service>/` | One folder per container on that host. Written by kolla-ansible, and overwritten by every `deploy` / `reconfigure` / `upgrade` |
| Logs | `/var/log/kolla/<service>/` | A symlink to the `kolla_logs` Docker volume. Some output only goes to `docker logs <container>` |
| Persistent data | `/var/lib/docker/volumes/` | Databases, RabbitMQ, Glance images, OVN databases, Keystone Fernet keys. **Back this up.** `/etc/kolla` on the nodes can be regenerated; this can't |
| Not in containers | the host itself | Docker, kernel modules and sysctl settings, `/etc/hosts`, time sync, and storage you prepared yourself (e.g. the `cinder-volumes` volume group) |

---

## What `config.json` is

Each `/etc/kolla/<service>/` folder contains the service's config files plus a
`config.json`, which tells the container how to set itself up when it starts.

The folder is mounted read-only into the container at `/var/lib/kolla/config_files/`.
On every start, the container's entrypoint (`kolla_set_configs`) reads `config.json`
and:

1. **Copies each file** from `config_files` to its real location inside the container,
   with the given owner and permissions:
   ```json
   {
     "source": "/var/lib/kolla/config_files/keystone.conf",
     "dest": "/etc/keystone/keystone.conf",
     "owner": "keystone",
     "perm": "0600"
   }
   ```
   `"optional": true` means "skip it if the file isn't there".
2. **Fixes ownership** of the paths listed under `permissions`, such as log files and
   key folders.
3. **Runs `command`**, which is the service itself, e.g. `/usr/bin/keystone-startup.sh`.

kolla-ansible sets `KOLLA_CONFIG_STRATEGY=COPY_ALWAYS`, so this copy happens on every
container start. This has two consequences:

- The file the service actually reads is the **copy inside the container**, e.g.
  `/etc/keystone/keystone.conf`, not `/etc/kolla/keystone/keystone.conf` on the host.
- After changing a file in `/etc/kolla/<service>/`, the container has to restart to
  pick it up.

To see what a service is really running with:

```bash
docker exec <container> cat /etc/<service>/<service>.conf
```

---

## Making changes

Make every change on the **deployment host**, then apply it with kolla-ansible:

| What | Where, on the deployment host |
|---|---|
| Kolla settings (`enable_*`, interfaces, TLS, ...) | `/etc/kolla/globals.yml` or `/etc/kolla/globals.d/*.yml` |
| Which hosts run which services | your inventory file |
| Passwords and keys | `/etc/kolla/passwords.yml` |
| Service config (options in the `.conf` files) | `/etc/kolla/config/`, as below |

Service config files are merged, each one overriding the previous. Using Nova as the
example:

```
/etc/kolla/config/global.conf                        # every service
/etc/kolla/config/nova.conf                          # all Nova services, all hosts
/etc/kolla/config/nova/nova-compute.conf             # one service, all hosts
/etc/kolla/config/nova/<hostname>/nova.conf          # all Nova services, one host
/etc/kolla/config/nova/<hostname>/nova-compute.conf  # one service, one host
```

Apply:

```bash
kolla-ansible reconfigure -i <inventory> --tags <service>    # e.g. --tags nova
```

Editing `/etc/kolla/<service>/` on a node and restarting the container works for a
quick experiment, but the next `reconfigure`, `deploy` or `upgrade` silently
overwrites it.

---

## First checks

From the deployment host, with the venv active and `admin-openrc.sh` sourced:

```bash
openstack compute service list        # nova-compute / scheduler / conductor "up"?
openstack network agent list          # OVN agents "Alive"?
openstack volume service list         # cinder-volume "up"?
openstack endpoint list               # every service registered, with the right scheme (https?)
```

On a node:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'   # look for "unhealthy" or "Restarting"
docker logs --tail 100 <container>                   # startup errors
tail -f /var/log/kolla/<service>/*.log               # the service's own logs
docker restart <container>
```

Run the same command on many nodes from the deployment host:

```bash
ansible -i <inventory> compute -b -m shell -a "docker ps --filter health=unhealthy"
```

With `-m shell -a`, Ansible tries to template anything in `{{ }}`, which breaks
`docker --format` strings. Put those commands in a script and run it with
`-m script -a ./check.sh` instead.

---

## Networking

**SSH to an instance without a floating IP.** Every compute node running an instance
on a network has an OVN metadata namespace for it, `ovnmeta-<network-id>`, with an
address in that network. Go through it from the deployment host, so the instance's
private key never leaves your machine:

```bash
ssh -i <instance-key> \
  -o ProxyCommand="ssh <user>@<compute-node> sudo ip netns exec ovnmeta-<network-id> nc %h %p" \
  <image-user>@<instance-private-ip>
```

**Floating IPs or outbound traffic not working.** Watch the external NIC on the gateway
node (in the `network` group) while an instance pings out:

```bash
sudo tcpdump -eni <neutron_external_interface> 'arp or icmp'
```

- **Nothing appears:** the problem is inside the cloud. Check the router's external
  gateway, `openstack network agent list`, and the security groups.
- **Repeated `who-has <gateway> tell <router-ip>` with no reply:** packets leave the
  node, but nothing on the external network answers. Either the upstream gateway
  doesn't exist, or something in between drops the traffic. When the nodes are
  themselves VMs in another cloud, the usual cause is port security on the outer
  port, because the router sends from its own MAC address, not the NIC's.

Check how the external bridge is wired on that node:

```bash
docker exec openvswitch_vswitchd ovs-vsctl list-ports br-ex                        # should include your external NIC
docker exec ovn_controller ovs-vsctl get open . external_ids:ovn-bridge-mappings  # e.g. "physnet1:br-ex"
```

### OVS and OVN

With `neutron_plugin_agent: "ovn"`, there are three layers:

| Layer | What it holds | Where | Container |
|---|---|---|---|
| **Northbound DB** | What Neutron asked for: logical switches (networks), routers, NAT/floating IPs, load balancers, security groups | controllers, TCP 6641 | `ovn_nb_db` |
| **Southbound DB** | What `ovn-northd` compiled that into: logical flows, plus every node ("chassis") and which node each port lives on | controllers, TCP 6642 (nodes connect through a relay, TCP 16641) | `ovn_sb_db`, `ovn_sb_db_relay_*` |
| **Open vSwitch** | The actual switch on each node: `br-int` (all instance ports and Geneve tunnels), `br-ex` (external NIC) | every node | `openvswitch_vswitchd`, `ovn_controller` |

**Names map straight back to Neutron.** Network `<id>` is logical switch
`neutron-<id>`, router `<id>` is `neutron-<id>`, and each logical switch port is named
after its Neutron port ID. `ovn-nbctl show` also prints the Neutron name as `(aka ...)`.

**What runs where.** The packet switching itself happens in the host's Linux kernel:
the `openvswitch` and `geneve` kernel modules. The bridges are real host devices, so
`ip link` on a node shows `br-int`, `br-ex`, `ovs-system` and `genev_sys_6081`. The
containers run the programs that configure and control the switch:

| Container | Runs on | Program | Role |
|---|---|---|---|
| `openvswitch_db` | every node | `ovsdb-server` | Stores this node's OVS config (bridges, ports), in the `openvswitch_db` volume |
| `openvswitch_vswitchd` | every node | `ovs-vswitchd` | Applies that config to the kernel and handles forwarding rules. Privileged, with host PID and `/lib/modules`, because it drives the kernel module |
| `ovn_controller` | every node | `ovn-controller` | Pulls this node's logical flows from the Southbound relay and hands them to `ovs-vswitchd` |
| `ovn_nb_db` | controllers | `ovsdb-server` | Northbound DB. `neutron_server` writes here |
| `ovn_northd` | controllers | `ovn-northd` | Compiles Northbound into Southbound logical flows |
| `ovn_sb_db` | controllers | `ovsdb-server` | Southbound DB |
| `ovn_sb_db_relay_1` | controllers | `ovsdb-server` | Southbound relay that every `ovn_controller` connects to |

All of these use the host's network, not a container network, so what they create is
visible on the host as usual. The OVS/OVN command-line tools only exist inside the
images, hence `docker exec`. They talk to the host's real OVS through the shared socket
`/run/openvswitch/db.sock`.

If `openvswitch_vswitchd` stops, traffic that already has a cached kernel flow may keep
working for a while, but anything new is dropped until it's back. Restarting or
upgrading these containers briefly interrupts networking on that node.

**Where the OVN databases live.** Only on the hosts in the `ovn-database` inventory
group, which by default is `control`. Compute nodes keep no copy. Data is in Docker
volumes on those controllers:

```
/var/lib/docker/volumes/ovn_nb_db/_data/ovnnb.db
/var/lib/docker/volumes/ovn_sb_db/_data/ovnsb.db
```

Both are Raft log files, so never edit them directly. Only Northbound is worth backing
up: `ovn-northd` rebuilds Southbound from it.

| Port | Listens on | What | Clients |
|---|---|---|---|
| 6641 | all interfaces | Northbound DB | `neutron_server` |
| 6642 | all interfaces | Southbound DB | `ovn_northd`, the relay, the metadata agents |
| 16641 | management IP | Southbound relay | `ovn_controller` on every node |
| 6643 / 6644 | management IP | Raft traffic between database members | other controllers |

**Security:** 6641 and 6642 listen on every interface, over plain TCP, with no
authentication, and kolla-ansible has no TLS option for them. Anyone who can reach
those ports can read or change the whole network layout. Keep them reachable only from
your own nodes, with a firewall or network separation.

**Open vSwitch**, on any node:

```bash
docker exec openvswitch_vswitchd ovs-vsctl show                  # bridges, ports, Geneve tunnels to other nodes
docker exec openvswitch_vswitchd ovs-ofctl dump-flows br-int     # OpenFlow rules OVN programmed (long)
docker exec openvswitch_vswitchd ovs-appctl dpctl/dump-flows     # flows the kernel is actually using right now
docker exec ovn_controller ovs-vsctl get open . external_ids     # this node's OVN settings: ovn-remote, encap IP, bridge mappings
docker exec ovn_controller ovn-appctl -t ovn-controller connection-status   # "connected" to the Southbound DB?
```

In `ovs-vsctl show`, an `error: "could not open network device ..."` line means a
port is configured for a NIC that doesn't exist on that node.

**Northbound DB**, on a controller:

```bash
docker exec ovn_nb_db ovn-nbctl show                        # all switches and routers, with their ports
docker exec ovn_nb_db ovn-nbctl ls-list                     # logical switches (networks)
docker exec ovn_nb_db ovn-nbctl lr-list                     # logical routers
docker exec ovn_nb_db ovn-nbctl lsp-list neutron-<network-id>   # ports on one network
docker exec ovn_nb_db ovn-nbctl lr-nat-list neutron-<router-id> # SNAT and floating IPs on a router
docker exec ovn_nb_db ovn-nbctl lr-route-list neutron-<router-id>
docker exec ovn_nb_db ovn-nbctl lb-list                     # OVN load balancers (Octavia's OVN provider)
docker exec ovn_nb_db ovn-nbctl acl-list pg_<security-group-id-with-underscores>   # a security group's rules
```

Each security group becomes a port group named `pg_` plus its ID with `-` replaced by
`_`. The extra `neutron_pg_drop` group holds the default "drop everything else" rules
for ports with port security enabled.

**Southbound DB**, on a controller:

```bash
docker exec ovn_sb_db ovn-sbctl show                        # every chassis, and the ports bound to each
docker exec ovn_sb_db ovn-sbctl find Port_Binding logical_port=<neutron-port-id>   # which node hosts this port?
docker exec ovn_sb_db ovn-sbctl find Port_Binding type=chassisredirect             # which node is the active gateway for each router
docker exec ovn_sb_db ovn-sbctl lflow-list neutron-<network-id>                    # logical flows for one network
```

**Trace a packet** through the logical pipeline, without sending anything. This shows
which rule allows or drops it:

```bash
docker exec ovn_sb_db ovn-trace --summary neutron-<network-id> \
  'inport=="<neutron-port-id>" && eth.src==<port-mac> && ip4.src==<port-ip> &&
   ip4.dst==<destination-ip> && ip.ttl==64 && icmp4.type==8'
```

### Checking the OVS/OVN services themselves

**Are they running?** Run on each node:

```bash
docker ps -a --filter name=ovn --filter name=openvswitch --format 'table {{.Names}}\t{{.Status}}'
```

Only the `openvswitch_*` containers have health checks. The `ovn_*` ones just show
`Up`, so use the commands below to confirm they actually work.

**Status commands:**

```bash
# every node
docker exec openvswitch_vswitchd ovs-appctl version                              # vswitchd answering?
docker exec openvswitch_db ovs-appctl -t ovsdb-server ovsdb-server/list-dbs     # should list Open_vSwitch
docker exec ovn_controller ovn-appctl -t ovn-controller connection-status       # "connected"
docker exec ovn_controller ovn-appctl -t ovn-controller debug/status            # "running"

# controllers
docker exec ovn_northd ovn-appctl -t /var/run/ovn/ovn-northd.ctl status                  # "Status: active" (one active northd; others "standby")
docker exec ovn_northd ovn-appctl -t /var/run/ovn/ovn-northd.ctl sb-connection-status    # "connected"
docker exec ovn_nb_db ovn-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound
docker exec ovn_sb_db ovn-appctl -t /var/run/ovn/ovnsb_db.ctl cluster/status OVN_Southbound
docker exec ovn_sb_db_relay_1 ovn-appctl -t /var/run/ovn/ovnsb_db_relay_1.ctl ovsdb-server/list-dbs   # should list OVN_Southbound
docker exec ovn_sb_db ovn-sbctl show     # every node should appear as a chassis; a missing one means its ovn_controller isn't connected
```

The databases run as Raft clusters even with one controller. `cluster/status` shows the
members and which one is leader.

**Logs:**

| File, under `/var/log/kolla/` | What |
|---|---|
| `openvswitch/ovs-vswitchd.log`, `openvswitch/ovsdb-server.log` | OVS on this node (bridges, ports, missing NICs) |
| `openvswitch/ovn-controller.log` | This node's connection to OVN, and port binding |
| `openvswitch/ovn-northd.log` | Northbound → Southbound translation (controllers) |
| `openvswitch/ovn-nb-db.log`, `openvswitch/ovn-sb-db.log`, `openvswitch/ovn-sb-relay-1.log` | The databases (controllers) |
| `neutron/neutron-server.log` | Neutron's writes to the Northbound DB. Errors here mean OVN never heard about a change |
| `neutron/neutron-ovn-metadata-agent.log` | Instance metadata (169.254.169.254) on each node |
| `neutron/neutron-ovn-maintenance-worker.log` | Neutron's periodic Neutron ↔ OVN consistency fixes |

**Restarting by hand** (safe, but briefly interrupts networking on that node). Restart
in this order, so each program finds what it depends on:

```bash
# on a node
docker restart openvswitch_db openvswitch_vswitchd ovn_controller
# on a controller, if the databases or northd are the problem
docker restart ovn_nb_db ovn_sb_db ovn_sb_db_relay_1 ovn_northd
```

**Redeploying their config** from the deployment host:

```bash
kolla-ansible reconfigure -i <inventory> --tags openvswitch     # OVS on every node
kolla-ansible reconfigure -i <inventory> --tags ovn             # ovn-controller + the OVN databases/northd
kolla-ansible reconfigure -i <inventory> --tags neutron         # neutron_server and the metadata agents
```

`--tags ovn-controller` or `--tags ovn-db` narrows `ovn` down to one half.

---

## TLS

- **Look at the certificate a service presents:**
  ```bash
  openssl s_client -connect <vip>:5000 -CAfile /etc/kolla/certificates/ca/root.crt </dev/null | head -20
  ```
- **See which names it covers:**
  ```bash
  openssl x509 -in /etc/kolla/certificates/haproxy.pem -noout -text | grep -A1 "Subject Alternative Name"
  ```
  Clients must connect with one of these names. With a self-signed lab certificate
  that's often only the VIP's IP address, so `https://localhost:<port>` through a port
  forward fails even when the CA is trusted.
- **`SSLError(PermissionError(13, 'Permission denied'))` from the `openstack` CLI:** the
  CLI can't read the CA file in `OS_CACERT`. The usual cause is the snap-packaged
  `openstack` (`which openstack` shows `/snap/bin/openstack`), whose sandbox isn't
  allowed to read `/etc/kolla`. Install `python-openstackclient` in the kolla venv
  instead.
- **`admin-openrc.sh` still shows `http://` after enabling TLS:** it's only regenerated
  by `kolla-ansible post-deploy`. Also check the setting reached the file kolla actually
  reads (`/etc/kolla/globals.yml` or `/etc/kolla/globals.d/`), not just a copy elsewhere.
