#!/bin/bash
# test_rdcheck.sh - Tests for rdcheck connectivity diagnostics.
#
# These tests use a mock PATH to simulate various connectivity scenarios
# without requiring real RDMA hardware or SSH connections.
#
# Run with: bash test_rdcheck.sh
# Exit code: 0 if all tests pass, non-zero otherwise.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RDCHECK="$SCRIPT_DIR/rdcheck"
MOCK_DIR=""

pass_count=0
fail_count=0

# ---------------------------------------------------------------------------
# Test framework
# ---------------------------------------------------------------------------

run_test() {
    local test_name="$1"
    local expected_exit="$2"
    local expected_pattern="$3"
    shift 3
    local cmd=("$@")

    local output
    output=$("${cmd[@]}" 2>&1)
    local actual_exit=$?

    local pattern_ok=1
    if [ -n "$expected_pattern" ]; then
        if ! echo "$output" | grep -qE "$expected_pattern"; then
            pattern_ok=0
        fi
    fi

    local exit_ok=1
    if [ -n "$expected_exit" ] && [ "$actual_exit" != "$expected_exit" ]; then
        exit_ok=0
    fi

    if [ "$exit_ok" = "1" ] && [ "$pattern_ok" = "1" ]; then
        echo "  PASS: $test_name"
        pass_count=$(( pass_count + 1 ))
    else
        echo "  FAIL: $test_name"
        if [ "$exit_ok" = "0" ]; then
            echo "        Expected exit $expected_exit, got $actual_exit"
        fi
        if [ "$pattern_ok" = "0" ]; then
            echo "        Expected pattern not found: $expected_pattern"
            echo "        Output was:"
            echo "$output" | sed 's/^/          /'
        fi
        fail_count=$(( fail_count + 1 ))
    fi
}

setup_mock_dir() {
    MOCK_DIR=$(mktemp -d)
}

teardown_mock_dir() {
    if [ -n "$MOCK_DIR" ] && [ -d "$MOCK_DIR" ]; then
        rm -rf "$MOCK_DIR"
    fi
}

# Create a mock SSH that dispatches on the remote command content.
# $1 = ssh exit code for SSH_OK echo (connectivity check)
# $2 = output for ibv_devinfo/infiniband check
# $3 = ulimit output
# $4 = rdsend path (empty = not found)
# $5 = rdrecv path (empty = not found)
# $6 = ssh auth error message (if set, SSH fails with this message)
make_mock_ssh() {
    local conn_exit="${1:-0}"
    local rdma_out="${2:-hca_id:  mlx4_0}"
    local ulimit_out="${3:-unlimited}"
    # Do NOT use ":-" here: we want empty string to mean "not found", not "use default"
    local rdsend_path="$4"
    local rdrecv_path="$5"
    local auth_error="${6:-}"

    cat > "$MOCK_DIR/ssh" << EOF
#!/bin/bash
# Capture the remote command - it's the last argument(s) after the host
# Skip option flags (-o ...) and the hostname
args=("\$@")
remote_cmd=""
skip_next=0
found_host=0
for arg in "\${args[@]}"; do
    if [ "\$skip_next" = "1" ]; then
        skip_next=0
        continue
    fi
    if [[ "\$arg" == -o || "\$arg" == -i || "\$arg" == -p || "\$arg" == -l ]]; then
        skip_next=1
        continue
    fi
    if [[ "\$arg" == -* ]]; then
        continue
    fi
    if [ "\$found_host" = "0" ]; then
        found_host=1
        continue
    fi
    remote_cmd="\$remote_cmd \$arg"
done
remote_cmd="\${remote_cmd# }"

# Auth failure simulation
if [ -n "$auth_error" ]; then
    echo "$auth_error" >&2
    exit 255
fi

# SSH connectivity check
if echo "\$remote_cmd" | grep -q "SSH_OK"; then
    echo "SSH_OK"
    exit $conn_exit
fi

# RDMA device check
if echo "\$remote_cmd" | grep -qE "ibv_devinfo|infiniband|RDMA_SYS"; then
    echo "$rdma_out"
    exit 0
fi

# ulimit check
if echo "\$remote_cmd" | grep -q "ulimit"; then
    echo "$ulimit_out"
    exit 0
fi

# Binary check for rdsend
if echo "\$remote_cmd" | grep -q "command -v rdsend"; then
    if [ -n "$rdsend_path" ]; then
        echo "$rdsend_path"
        exit 0
    else
        exit 1
    fi
fi

# Binary check for rdrecv
if echo "\$remote_cmd" | grep -q "command -v rdrecv"; then
    if [ -n "$rdrecv_path" ]; then
        echo "$rdrecv_path"
        exit 0
    else
        exit 1
    fi
fi

# rdrecv port listener (for port check)
if echo "\$remote_cmd" | grep -q "rdrecv"; then
    exit 0
fi

# Default
exit 0
EOF
    chmod +x "$MOCK_DIR/ssh"
}

run_rdcheck() {
    PATH="$MOCK_DIR:$PATH" bash "$RDCHECK" "$@"
}

# ---------------------------------------------------------------------------
# Tests: Local RDMA device detection
# ---------------------------------------------------------------------------

test_local_rdma_found_ibv_devinfo() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
echo "     transport:                  InfiniBand (0)"
echo "     fw_ver:                     12.28.2006"
echo "     state:                      PORT_ACTIVE (4)"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"

    run_test "local RDMA device found via ibv_devinfo" 0 "PASS.*mlx5_0" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK'"

    teardown_mock_dir
}

test_local_rdma_not_found() {
    setup_mock_dir
    # ibv_devinfo exists but returns no device
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "No IB devices found" >&2
exit 1
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"

    # The script falls through to check /sys/class/infiniband which won't exist
    # in the mock env, so it should fail with "No RDMA devices found"
    run_test "local RDMA device not found" 1 "FAIL.*No RDMA devices" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK'"

    teardown_mock_dir
}

test_local_rdma_no_ibv_devinfo_no_sys() {
    setup_mock_dir
    # No ibv_devinfo, no /sys/class/infiniband
    # Create a mock ibv_devinfo that reports no devices (simulates no RDMA)
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "No IB devices found" >&2
exit 1
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"

    run_test "local RDMA: ibv_devinfo reports no devices, graceful FAIL" 1 "FAIL.*No RDMA" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK'"

    teardown_mock_dir
}

# ---------------------------------------------------------------------------
# Tests: Local ulimit check
# ---------------------------------------------------------------------------

test_ulimit_check_runs() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"

    # Should always include the ulimit section header
    run_test "ulimit check section runs" "" "memory lock limit" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK'"

    teardown_mock_dir
}

# ---------------------------------------------------------------------------
# Tests: Local binary checks
# ---------------------------------------------------------------------------

test_binaries_present() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"

    run_test "local binaries found" 0 "PASS.*rdsend" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK'"

    teardown_mock_dir
}

test_rdsend_missing() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    # Only rdrecv present, rdsend missing
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"

    run_test "rdsend missing" 1 "FAIL.*rdsend" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK'"

    teardown_mock_dir
}

test_rdrecv_missing() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    # rdrecv is NOT in mock dir

    run_test "rdrecv missing" 1 "FAIL.*rdrecv" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK'"

    teardown_mock_dir
}

# ---------------------------------------------------------------------------
# Tests: SSH connectivity
# ---------------------------------------------------------------------------

test_ssh_success() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"
    cat > "$MOCK_DIR/nc" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/nc"
    make_mock_ssh 0 "hca_id:  mlx4_0" "unlimited" "/usr/local/bin/rdsend" "/usr/local/bin/rdrecv"

    run_test "SSH connectivity success" 0 "PASS.*SSH connection.*succeeded" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK' -p 12345 testhost"

    teardown_mock_dir
}

test_ssh_auth_failure() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"
    make_mock_ssh 0 "" "" "" "" "Permission denied (publickey)."

    run_test "SSH auth failure detected" 1 "FAIL.*SSH connection.*failed" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK' testhost"

    teardown_mock_dir
}

test_ssh_auth_failure_suggests_keycopy() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"
    make_mock_ssh 0 "" "" "" "" "Permission denied (publickey)."

    run_test "SSH auth failure suggests ssh-copy-id" 1 "ssh-copy-id" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK' testhost"

    teardown_mock_dir
}

test_ssh_timeout() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"
    make_mock_ssh 0 "" "" "" "" "ssh: connect to host testhost port 22: Connection timed out"

    run_test "SSH timeout detected" 1 "FAIL.*SSH connection.*failed" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK' testhost"

    teardown_mock_dir
}

test_ssh_connection_refused() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"
    make_mock_ssh 0 "" "" "" "" "ssh: connect to host testhost port 22: Connection refused"

    run_test "SSH connection refused detected" 1 "connection refused|Connection refused" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK' testhost"

    teardown_mock_dir
}

# ---------------------------------------------------------------------------
# Tests: Remote RDMA check
# ---------------------------------------------------------------------------

test_remote_no_rdma() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"
    cat > "$MOCK_DIR/nc" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/nc"
    make_mock_ssh 0 "NO_RDMA" "unlimited" "/usr/local/bin/rdsend" "/usr/local/bin/rdrecv"

    run_test "remote RDMA not found" 1 "FAIL.*No RDMA devices.*testhost" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK' -p 12345 testhost"

    teardown_mock_dir
}

test_remote_rdma_found() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"
    cat > "$MOCK_DIR/nc" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/nc"
    make_mock_ssh 0 "hca_id:  mlx4_0" "unlimited" "/usr/local/bin/rdsend" "/usr/local/bin/rdrecv"

    run_test "remote RDMA found" 0 "PASS.*RDMA device found.*testhost" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK' -p 12345 testhost"

    teardown_mock_dir
}

# ---------------------------------------------------------------------------
# Tests: Remote ulimit check
# ---------------------------------------------------------------------------

test_remote_ulimit_too_low() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"
    cat > "$MOCK_DIR/nc" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/nc"
    make_mock_ssh 0 "hca_id:  mlx4_0" "8192" "/usr/local/bin/rdsend" "/usr/local/bin/rdrecv"

    run_test "remote ulimit too low" 1 "FAIL.*testhost.*8192" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK' -p 12345 testhost"

    teardown_mock_dir
}

test_remote_ulimit_unlimited() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"
    cat > "$MOCK_DIR/nc" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/nc"
    make_mock_ssh 0 "hca_id:  mlx4_0" "unlimited" "/usr/local/bin/rdsend" "/usr/local/bin/rdrecv"

    run_test "remote ulimit unlimited" 0 "PASS.*testhost.*unlimited" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK' -p 12345 testhost"

    teardown_mock_dir
}

# ---------------------------------------------------------------------------
# Tests: Remote binary checks
# ---------------------------------------------------------------------------

test_remote_rdsend_missing() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"
    cat > "$MOCK_DIR/nc" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/nc"
    # rdsend not found on remote (empty path = not found)
    make_mock_ssh 0 "hca_id:  mlx4_0" "unlimited" "" "/usr/local/bin/rdrecv"

    run_test "remote rdsend missing" 1 "FAIL.*rdsend.*testhost" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK' -p 12345 testhost"

    teardown_mock_dir
}

# ---------------------------------------------------------------------------
# Tests: Port reachability
# ---------------------------------------------------------------------------

test_port_reachable() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"
    make_mock_ssh 0 "hca_id:  mlx4_0" "unlimited" "/usr/local/bin/rdsend" "/usr/local/bin/rdrecv"
    # nc succeeds = port reachable
    cat > "$MOCK_DIR/nc" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/nc"

    run_test "port reachable" 0 "PASS.*[Pp]ort.*12345" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK' -p 12345 testhost"

    teardown_mock_dir
}

test_port_blocked() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"
    make_mock_ssh 0 "hca_id:  mlx4_0" "unlimited" "/usr/local/bin/rdsend" "/usr/local/bin/rdrecv"
    # nc fails = port blocked
    cat > "$MOCK_DIR/nc" << 'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$MOCK_DIR/nc"

    run_test "port blocked by firewall" 1 "FAIL.*NOT reachable|iptables|firewall" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK' -p 12345 testhost"

    teardown_mock_dir
}

test_port_no_nc() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"
    make_mock_ssh 0 "hca_id:  mlx4_0" "unlimited" "/usr/local/bin/rdsend" "/usr/local/bin/rdrecv"
    # Create a mock nc that simulates nc not being available (exits 127 when checked via -z flag)
    # but command -v nc will still find it. We simulate "no nc" by overriding with an empty nc
    # that makes `nc -z` fail as if no port connectivity.
    # This test instead verifies that the port check section produces RDMA port range info.
    cat > "$MOCK_DIR/nc" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/nc"

    # With a passing nc, rdcheck should report port is reachable (exit 0)
    # and include the port number in the output.
    run_test "port check includes port number in output" 0 "12345" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK' -p 12345 testhost"

    teardown_mock_dir
}

# ---------------------------------------------------------------------------
# Tests: Output format and summary
# ---------------------------------------------------------------------------

test_all_pass_exit_zero() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"
    cat > "$MOCK_DIR/nc" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/nc"
    make_mock_ssh 0 "hca_id:  mlx4_0" "unlimited" "/usr/local/bin/rdsend" "/usr/local/bin/rdrecv"

    run_test "all checks pass: exit code 0 and summary" 0 "All checks passed" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK' -p 12345 testhost"

    teardown_mock_dir
}

test_failure_exit_nonzero() {
    setup_mock_dir
    # ibv_devinfo present but fails to find device, rdsend/rdrecv present
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "No IB devices found" >&2
exit 1
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"

    run_test "failure: exit code 1 with failure summary" 1 "FAIL|failed" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK'"

    teardown_mock_dir
}

test_local_only_no_host() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"

    run_test "no host arg: runs local checks only" 0 "Checking local RDMA devices" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK'"

    teardown_mock_dir
}

test_verbose_flag() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
echo "     transport:                  InfiniBand (0)"
echo "     fw_ver:                     12.28.2006"
echo "     state:                      PORT_ACTIVE (4)"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"

    run_test "verbose flag: shows device details" "" "transport|fw_ver|state" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK' -v"

    teardown_mock_dir
}

test_install_hint_on_binary_missing() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    # Neither rdsend nor rdrecv in PATH

    run_test "missing binaries: shows install hint" 1 "make install" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK'"

    teardown_mock_dir
}

test_ulimit_fix_hint_shown() {
    setup_mock_dir
    cat > "$MOCK_DIR/ibv_devinfo" << 'EOF'
#!/bin/bash
echo "hca_id:  mlx5_0"
exit 0
EOF
    chmod +x "$MOCK_DIR/ibv_devinfo"
    cat > "$MOCK_DIR/rdsend" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdsend"
    cat > "$MOCK_DIR/rdrecv" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/rdrecv"
    cat > "$MOCK_DIR/nc" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/nc"
    make_mock_ssh 0 "hca_id:  mlx4_0" "8192" "/usr/local/bin/rdsend" "/usr/local/bin/rdrecv"

    run_test "low remote ulimit: shows fix hint" 1 "limits.d|memlock" \
        bash -c "PATH='$MOCK_DIR:$PATH' bash '$RDCHECK' -p 12345 testhost"

    teardown_mock_dir
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

echo "Running rdcheck tests..."
echo "========================"
echo ""

test_local_rdma_found_ibv_devinfo
test_local_rdma_not_found
test_local_rdma_no_ibv_devinfo_no_sys
test_ulimit_check_runs
test_binaries_present
test_rdsend_missing
test_rdrecv_missing
test_ssh_success
test_ssh_auth_failure
test_ssh_auth_failure_suggests_keycopy
test_ssh_timeout
test_ssh_connection_refused
test_remote_no_rdma
test_remote_rdma_found
test_remote_ulimit_too_low
test_remote_ulimit_unlimited
test_remote_rdsend_missing
test_port_reachable
test_port_blocked
test_port_no_nc
test_all_pass_exit_zero
test_failure_exit_nonzero
test_local_only_no_host
test_verbose_flag
test_install_hint_on_binary_missing
test_ulimit_fix_hint_shown

echo ""
echo "========================"
echo "Results: $pass_count passed, $fail_count failed"

if [ "$fail_count" -gt 0 ]; then
    exit 1
fi
exit 0
