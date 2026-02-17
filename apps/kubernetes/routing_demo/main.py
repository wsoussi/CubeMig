from flask import Flask, jsonify
import os

app = Flask(__name__)

COUNTER_FILE = "/tmp/counter.txt"

def _read_counter() -> int:
    try:
        with open(COUNTER_FILE, "r", encoding="utf-8") as f:
            return int(f.read().strip() or "0")
    except FileNotFoundError:
        return 0
    except Exception:
        return 0

def _write_counter(value: int) -> None:
    tmp_file = COUNTER_FILE + ".tmp"
    with open(tmp_file, "w", encoding="utf-8") as f:
        f.write(str(value))
    os.replace(tmp_file, COUNTER_FILE)

def _read_text(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as f:
            v = f.read().strip()
            return v if v else "unknown"
    except Exception:
        return "unknown"

@app.route("/whoami")
def whoami():
    current = _read_counter() + 1
    _write_counter(current)

    return jsonify({
        "cluster": _read_text("/etc/podinfo/cluster"),
        "version": _read_text("/etc/podinfo/version"),
        "counter": current
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)