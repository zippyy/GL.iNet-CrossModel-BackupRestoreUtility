# Native OpenWrt package

The package source in `luci-app-glinet-crossmodel-backup/` is canonical. It
contains the LuCI controller/view, local/controller CLI, streamed remote
coordinator, shared runtime, GL Admin Panel integration, default retention
configuration, and sysupgrade keep declaration.

The same architecture-independent IPK supports local/direct and agentless
controller operation. Remote endpoints need SSH, standard OpenWrt tools, and
SHA-256 support; they do not need the package installed.

Build with the repository builder:

```sh
bash scripts/build-openwrt-ipk.sh
```

Or copy the package directory into a matching OpenWrt/GL.iNet SDK and run:

```sh
make package/luci-app-glinet-crossmodel-backup/compile V=s
```

Runtime behavior is never introduced by the builder. See the root README for
CLI/controller examples, archive v2, strategy guarantees, Package Review,
legacy behavior, and real-router validation requirements.
