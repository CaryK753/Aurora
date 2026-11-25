import Foundation

enum UpdateInstaller {
    /// 只有通过单实例检查并完成 AppKit 启动的新进程才确认接管。
    static func acknowledgeLaunch() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--aurora-update-launch"),
              arguments.indices.contains(index + 1),
              let token = UUID(uuidString: arguments[index + 1]) else { return }
        let transaction = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(".aurora-update-" + token.uuidString, isDirectory: true)
        try? Data().write(to: transaction.appendingPathComponent("started"), options: .atomic)
    }

    static func script(bundleID: String) -> String {
        #"""
        set -eu
        APP="$1"
        SRC="$2"
        PID="$3"
        TEAM="$4"
        TOKEN="$5"
        STAGE="$6"
        WORK="$(dirname "$APP")/.aurora-update-$TOKEN"
        umask 077
        exec >>"$(dirname "$STAGE")/install.log" 2>&1
        echo "=== $(date) update"
        i=0
        while kill -0 "$PID" 2>/dev/null; do
          [ "$i" -lt 300 ] || { echo "old process still running"; exit 1; }
          sleep 0.2
          i=$((i+1))
        done
        mkdir "$WORK" || { /usr/bin/open "$APP"; exit 1; }
        # 在同一卷上准备完整的新包。旧版一直保留到新版完成启动。
        finish() {
          rc=$?
          trap - EXIT
          if [ "$rc" -ne 0 ]; then
            if [ -d "$WORK/previous" ]; then
              if [ -d "$APP" ]; then mv "$APP" "$WORK/failed" || exit 1; fi
              mv "$WORK/previous" "$APP" || exit 1
            fi
            /usr/bin/open "$APP" || echo "cannot reopen original app"
          fi
          rm -rf "$WORK"
          exit "$rc"
        }
        trap finish EXIT
        /usr/bin/ditto "$SRC" "$WORK/incoming"
        /usr/bin/xattr -dr com.apple.quarantine "$WORK/incoming" 2>/dev/null || true
        /usr/bin/codesign --verify --deep --strict "$WORK/incoming"
        BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$WORK/incoming/Contents/Info.plist")
        [ "$BID" = "\#(bundleID)" ] || exit 1
        ACTUAL=$(/usr/bin/codesign -dv --verbose=4 "$WORK/incoming" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')
        [ "$ACTUAL" = "$TEAM" ] || exit 1
        mv "$APP" "$WORK/previous"
        mv "$WORK/incoming" "$APP"
        running() { /bin/ps -axo comm= | /usr/bin/grep -Fxq "$APP/Contents/MacOS/Aurora"; }
        /usr/bin/open -n "$APP" --args --aurora-update-launch "$TOKEN" || echo "LaunchServices failed"
        i=0
        while [ ! -f "$WORK/started" ] && [ "$i" -lt 30 ]; do
          sleep 0.2
          i=$((i+1))
        done
        if [ ! -f "$WORK/started" ] && ! running; then
          echo "retrying installed executable"
          "$APP/Contents/MacOS/Aurora" --aurora-update-launch "$TOKEN" </dev/null &
          sleep 0.5
        fi
        i=0
        while [ ! -f "$WORK/started" ]; do
          running || { echo "new process exited before startup"; exit 1; }
          if [ "$i" -ge 120 ]; then
            # 活着但尚未确认的程序可能正等待系统授权，保留恢复副本，不覆盖运行中的应用。
            trap - EXIT
            echo "startup unconfirmed; backup retained in $WORK"
            exit 1
          fi
          sleep 0.5
          i=$((i+1))
        done
        echo "new process acknowledged launch"
        rm -rf "$STAGE" || echo "stage cleanup deferred"
        """#
    }
}
