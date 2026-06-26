# GL.iNet Admin Panel v4 integration IPK

This is a companion package for `luci-app-glinet-crossmodel-backup`.

It does not replace the backup/restore application. It moves the LuCI route to **System**, installs the GL.iNet Admin Panel v4 shortcut hook, and runs a boot-time repair hook so the integration is restored after the GL UI bootstrap file is replaced.

Build from the repository root:

```sh
sh openwrt/glui-integration/build-ipk.sh
```

The output uses the legacy gzip/tar IPK layout required by GL.iNet's OpenWrt 21.02 `opkg`.
