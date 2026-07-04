#!/usr/bin/env python3
import ctypes
import os
import sys
import tkinter as tk

log = "/tmp/ai-installer-gui-test.log"

def macos_make_foreground_app():
    if sys.platform != "darwin":
        return "skip"
    try:
        app_services = ctypes.CDLL(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        )
        class PSN(ctypes.Structure):
            _fields_ = [("highLongOfPSN", ctypes.c_uint32), ("lowLongOfPSN", ctypes.c_uint32)]
        psn = PSN()
        gcp = app_services.GetCurrentProcess(ctypes.byref(psn))
        tpt = app_services.TransformProcessType(ctypes.byref(psn), 1)
        return f"gcp={gcp} tpt={tpt}"
    except Exception as e:
        return f"err={e}"

result = macos_make_foreground_app()
with open(log, "w") as f:
    f.write(f"argv0={sys.argv[0]}\n")
    f.write(f"cwd={os.getcwd()}\n")
    f.write(f"transform={result}\n")

root = tk.Tk()
root.title("GUI Launch Test")
root.geometry("420x160")
lbl = tk.Label(
    root, text="If you can read this, Tk text works.",
    font=("Helvetica", 16, "bold"), fg="#1d1d1f", bg="#ffffff",
)
lbl.pack(expand=True, fill="both")
root.update_idletasks()
with open(log, "a") as f:
    f.write(f"label={lbl.winfo_reqwidth()}x{lbl.winfo_reqheight()}\n")
root.after(3000, root.destroy)
root.mainloop()