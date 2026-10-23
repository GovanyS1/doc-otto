"""Run without arguments for the window, or use --cli for terminal diagnostics."""

from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
import queue
import sys
import threading

from reader import network_interfaces, scan, summary


def save_report(report: dict, path: str | Path):
    Path(path).write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def launch_gui():
    import tkinter as tk
    from tkinter import filedialog, messagebox, ttk

    root = tk.Tk()
    root.title("Doc Otto · Windows test")
    root.geometry("850x660")
    root.minsize(700, 540)
    root.configure(background="#f4f6f8")
    style = ttk.Style(root)
    if "clam" in style.theme_names():
        style.theme_use("clam")
    style.configure("TFrame", background="#f4f6f8")
    style.configure("TLabel", background="#f4f6f8", foreground="#182b3a", font=("Segoe UI", 10))
    style.configure("Title.TLabel", font=("Segoe UI", 22, "bold"))
    style.configure("TButton", font=("Segoe UI", 10), padding=8)
    style.configure("Treeview", rowheight=30, font=("Segoe UI", 10))
    style.configure("Treeview.Heading", font=("Segoe UI", 10, "bold"))
    frame = ttk.Frame(root, padding=24)
    frame.pack(fill="both", expand=True)
    frame.columnconfigure(1, weight=1)
    frame.rowconfigure(7, weight=1)
    frame.rowconfigure(9, weight=1)
    ttk.Label(frame, text="Doc Otto", style="Title.TLabel").grid(row=0, column=0, columnspan=3, sticky="w")
    ttk.Label(frame, text="Windows prototype · test vehicle · Engine codes").grid(
        row=1, column=0, columnspan=3, sticky="w", pady=(2, 18))
    ttk.Label(frame, text="PC network interface").grid(row=2, column=0, sticky="w", padx=(0, 14))
    interface = tk.StringVar(value="Automatic (Windows routing)")
    choice = ttk.Combobox(frame, textvariable=interface, state="readonly")
    choice.grid(row=2, column=1, columnspan=2, sticky="ew", pady=4)
    ttk.Label(frame, text="Gateway / adapter IP").grid(row=3, column=0, sticky="w")
    host = tk.StringVar()
    host_entry = ttk.Entry(frame, textvariable=host)
    host_entry.grid(row=3, column=1, columnspan=2, sticky="ew", pady=4)
    ttk.Label(frame, text="Leave IP blank to discover the test vehicle. Select the interface connected to MHD Wi-Fi.").grid(
        row=4, column=0, columnspan=3, sticky="w", pady=(2, 12))
    actions = ttk.Frame(frame)
    actions.grid(row=5, column=0, columnspan=3, sticky="ew")
    status = tk.StringVar(value="Ready. Connect Windows to the MHD Wi-Fi network before scanning.")
    ttk.Label(frame, textvariable=status, wraplength=760).grid(
        row=6, column=0, columnspan=3, sticky="w", pady=(16, 10))
    tree = ttk.Treeview(frame, columns=("code", "status"), show="headings", height=5)
    tree.heading("code", text="BMW engine code")
    tree.heading("status", text="Reported status")
    tree.column("code", width=160, stretch=False)
    tree.column("status", width=560)
    tree.grid(row=7, column=0, columnspan=3, sticky="nsew")
    ttk.Label(frame, text="Connection log").grid(row=8, column=0, columnspan=3, sticky="w", pady=(12, 4))
    log = tk.Text(frame, height=7, wrap="word", font=("Consolas", 9), state="disabled",
                  background="#ffffff", foreground="#304557", relief="flat", padx=10, pady=8)
    log.grid(row=9, column=0, columnspan=3, sticky="nsew")
    ttk.Label(frame, text="Reads pending/confirmed DME codes. Other modules and fault descriptions are outside this test.",
              wraplength=760).grid(row=10, column=0, columnspan=3, sticky="w", pady=(12, 0))

    events = queue.Queue()
    state = {"report": None, "busy": False, "bindings": {"Automatic (Windows routing)": None}}

    def append_log(message):
        log.configure(state="normal")
        log.insert("end", message + "\n")
        log.see("end")
        log.configure(state="disabled")

    def scan_finished(report):
        state["report"] = report
        state["busy"] = False
        scan_button.configure(state="normal")
        refresh_button.configure(state="normal")
        save_button.configure(state="normal")
        choice.configure(state="readonly")
        host_entry.configure(state="normal")
        text = summary(report)
        if report["vin"]:
            text += " VIN: " + report["vin"]
        status.set(text)
        for fault in report["faults"] or []:
            flags = "; ".join(fault["status_flags"])
            tree.insert("", "end", values=(fault["code"], f"{flags} [0x{fault['status_hex']} ]"))

    def start_scan():
        if state["busy"]:
            return
        selected_host = host.get().strip() or None
        selected_bind = state["bindings"].get(interface.get())
        state["busy"] = True
        state["report"] = None
        for button in (scan_button, refresh_button, save_button):
            button.configure(state="disabled")
        choice.configure(state="disabled")
        host_entry.configure(state="disabled")
        tree.delete(*tree.get_children())
        log.configure(state="normal")
        log.delete("1.0", "end")
        log.configure(state="disabled")
        status.set("Reading engine codes…")

        def worker():
            try:
                report = scan(selected_host, selected_bind, lambda message: events.put(("log", message)))
                events.put(("done", report))
            except Exception as exc:
                events.put(("unexpected_error", f"Unexpected error: {exc}"))
        threading.Thread(target=worker, daemon=True).start()

    def refresh_interfaces():
        refresh_button.configure(state="disabled")
        threading.Thread(target=lambda: events.put(("interfaces", network_interfaces())), daemon=True).start()

    def save():
        report = state["report"]
        if report is None:
            return
        filename = f"doc-otto-scan-{datetime.now():%Y%m%d-%H%M%S}.json"
        path = filedialog.asksaveasfilename(defaultextension=".json", initialfile=filename,
                                          filetypes=[("JSON scan report", "*.json")])
        if path:
            try:
                save_report(report, path)
                append_log("Saved report: " + path)
            except OSError as exc:
                messagebox.showerror("Could not save report", str(exc))

    def poll():
        try:
            while True:
                kind, payload = events.get_nowait()
                if kind == "log":
                    append_log(payload)
                elif kind == "done":
                    scan_finished(payload)
                elif kind == "interfaces":
                    bindings = {"Automatic (Windows routing)": None}
                    for item in payload:
                        bindings[f"{item['name']} — {item['ip']}"] = item["ip"]
                    state["bindings"] = bindings
                    choice.configure(values=list(bindings))
                    if len(bindings) > 1:
                        choice.current(1)
                    else:
                        choice.current(0)
                    refresh_button.configure(state="normal")
                elif kind == "unexpected_error":
                    state["busy"] = False
                    scan_button.configure(state="normal")
                    refresh_button.configure(state="normal")
                    choice.configure(state="readonly")
                    host_entry.configure(state="normal")
                    status.set("Scan failed — code status is unknown.")
                    append_log(payload)
        except queue.Empty:
            pass
        root.after(80, poll)

    scan_button = ttk.Button(actions, text="Read engine codes", command=start_scan)
    scan_button.pack(side="left")
    refresh_button = ttk.Button(actions, text="Refresh interfaces", command=refresh_interfaces)
    refresh_button.pack(side="left", padx=8)
    save_button = ttk.Button(actions, text="Save report", command=save, state="disabled")
    save_button.pack(side="right")
    # Finish initial interface discovery before allowing a scan (avoids a UI race).
    scan_button.configure(state="disabled")
    refresh_interfaces()
    # Enable scanning once the initial list has arrived.
    def enable_initial_scan():
        if choice["values"]:
            scan_button.configure(state="normal")
        else:
            root.after(100, enable_initial_scan)
    root.after(100, enable_initial_scan)
    root.after(80, poll)
    root.mainloop()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Doc Otto: experimental BMW engine-code reader over ENET.")
    parser.add_argument("--cli", action="store_true", help="Use terminal instead of the window")
    parser.add_argument("--interfaces", action="store_true", help="List local network interface IPv4 addresses")
    parser.add_argument("--host", help="Verified gateway/adapter IPv4; omit for UDP discovery")
    parser.add_argument("--bind", help="PC Wi-Fi interface IPv4 to use")
    parser.add_argument("--timeout", type=float, default=6.0, help="Seconds per ECU request (default: 6)")
    parser.add_argument("--output", type=Path, help="Save diagnostic results and raw frames to JSON")
    args = parser.parse_args(argv)
    if args.interfaces:
        print(json.dumps(network_interfaces(), indent=2))
        return 0
    if args.cli or args.host or args.bind or args.output or args.timeout != 6.0:
        report = scan(args.host, args.bind, print, timeout=args.timeout)
        print("\n" + summary(report))
        if report["vin"]:
            print("VIN:", report["vin"])
        for fault in report["faults"] or []:
            print(f"  {fault['code']}  " + "; ".join(fault["status_flags"]))
        if args.output:
            try:
                save_report(report, args.output)
                print("Report saved:", args.output)
            except OSError as exc:
                print(f"Could not save report: {exc}", file=sys.stderr)
                return 2
        return 0 if report["dtc_status"] == "success" else 1
    try:
        launch_gui()
    except Exception as exc:
        print(f"Could not open the window: {exc}. Use --cli or install Python with Tcl/Tk.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
