#!/usr/bin/env bash
# Run inside a new OpenBayes Linux container. Existing Codex installs are reused.
set -euo pipefail

if command -v codex >/dev/null 2>&1; then
    printf 'Reusing existing Codex: %s\n' "$(command -v codex)"
    codex --version
    echo 'No installation changed. Check codex login status next.'
    exit 0
fi

ROOT=/openbayes/home/.codex-connect
if [ ! -d /openbayes/home ] || [ ! -w /openbayes/home ]; then
    echo 'Expected a writable persistent workspace at /openbayes/home.' >&2
    exit 1
fi
for tool in curl tar sha256sum awk uname; do
    command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }
done
case "$(uname -m)" in
    x86_64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo 'Supported architectures: Linux x86_64 and aarch64 (glibc).' >&2; exit 1 ;;
esac

umask 077
mkdir -p "$ROOT/bin" "$ROOT/npm" "$ROOT/downloads" /openbayes/home/.codex
chmod 700 /openbayes/home/.codex
if [ -f "$ROOT/proxy.env" ]; then . "$ROOT/proxy.env"; fi

if [ ! -x "$ROOT/node/bin/node" ]; then
    # Resolve the current Node 24 LTS binary from the official checksum list.
    base=https://nodejs.org/dist/latest-v24.x
    curl -fSL --connect-timeout 15 --max-time 180 "$base/SHASUMS256.txt" -o "$ROOT/downloads/SHASUMS256.txt"
    archive=$(awk -v suffix="-linux-$arch.tar.gz" 'index($2,suffix) && substr($2,length($2)-length(suffix)+1)==suffix {print $2; exit}' "$ROOT/downloads/SHASUMS256.txt")
    if [[ ! "$archive" =~ ^node-v24\.[0-9]+\.[0-9]+-linux-(x64|arm64)\.tar\.gz$ ]]; then
        echo 'Could not resolve an official Node 24 archive.' >&2
        exit 1
    fi
    curl -fSL --connect-timeout 15 --max-time 600 "$base/$archive" -o "$ROOT/downloads/$archive"
    (cd "$ROOT/downloads"; awk -v name="$archive" '$2==name' SHASUMS256.txt | sha256sum -c -)
    mkdir -p "$ROOT/node"
    tar -xzf "$ROOT/downloads/$archive" --strip-components=1 -C "$ROOT/node"
fi
export PATH="$ROOT/node/bin:$PATH"
node --version
npm install --global --prefix "$ROOT/npm" @openai/codex

cat > "$ROOT/bin/codex" <<'WRAPPER'
#!/usr/bin/env bash
set -e
ROOT=/openbayes/home/.codex-connect
export CODEX_HOME=/openbayes/home/.codex
export PATH="$ROOT/node/bin:$PATH"
if [ -f "$ROOT/proxy.env" ]; then . "$ROOT/proxy.env"; fi
exec "$ROOT/npm/bin/codex" "$@"
WRAPPER
chmod 700 "$ROOT/bin/codex"

# SSH starts a noninteractive shell: this line must precede .bashrc's early return.
path_line='export PATH="/openbayes/home/.codex-connect/bin:$PATH" # openbayes-codex-connect'
if ! grep -qxF "$path_line" "$HOME/.bashrc" 2>/dev/null; then
    if [ -f "$HOME/.bashrc" ]; then
        cp -p "$HOME/.bashrc" "$HOME/.bashrc.openbayes-$(date +%Y%m%d-%H%M%S).bak"
    fi
    temporary=$(mktemp "$HOME/.bashrc.openbayes.XXXXXX")
    printf '%s\n' "$path_line" > "$temporary"
    if [ -f "$HOME/.bashrc" ]; then cat "$HOME/.bashrc" >> "$temporary"; fi
    mv "$temporary" "$HOME/.bashrc"
fi
export PATH="$ROOT/bin:$PATH"
codex --version
printf '%s\n' 'OPENBAYES_CODEX_INSTALLED' 'Next: open a new SSH session and run codex login --device-auth.'
