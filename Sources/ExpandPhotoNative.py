#!/usr/bin/env python3
"""Original-Photos Extend bridge; no OS policy changes or library edits.

Requires the user-configured SIP-disabled research machine and open original
Photos. The app currently restricts this backend to the Trip album. Inference
uses Apple's online service. Finished stills are cached independently of motion.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
PHOTOS = "/System/Applications/Photos.app/Contents/MacOS/Photos"
JOBS = Path.home()/"Library/Containers/com.apple.Photos/Data/Library/Caches/SpatialSlideshow-ExtendResearch"
SUPPORT = Path.home()/"Library/Application Support/Photos Spatial Slideshow"
cancelled = False
current_job = None
attach_started = False


def progress(message):
    print("PROGRESS " + message, flush=True)


def sha(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for part in iter(lambda: stream.read(1024*1024), b""): h.update(part)
    return h.hexdigest()


def write_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True)+"\n")
    os.replace(temporary, path)


def read_json(path):
    try: return json.loads(Path(path).read_text())
    except (OSError, ValueError): return {}


def png_size(path):
    with Path(path).open("rb") as stream: header = stream.read(24)
    if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise RuntimeError("Native Extend did not save a valid PNG.")
    return list(struct.unpack(">II", header[16:24]))


def interrupted(signum, frame):
    global cancelled
    cancelled = True
    if current_job: (current_job/"cancel").touch()


def check_cancel():
    if cancelled:
        if current_job and not attach_started and not (current_job/"result.json").exists():
            write_json(current_job/"result.json",{"status":"failed","message":"Cancelled before request submission."})
        raise RuntimeError("Apple Photos Extend cancelled.")


def check_runtime(prepare):
    files = [HERE/"attach_jit.py", HERE/"JITRequest.expr", HERE/"ExpandPhotoNative.py", Path(prepare)]
    if not all(p.is_file() for p in files):
        raise RuntimeError("The native Extend research helpers are missing. Rebuild Spatial Slideshow.")
    sip = subprocess.check_output(["/usr/bin/csrutil", "status"],text=True).strip()
    if sip != "System Integrity Protection status: disabled.":
        raise RuntimeError("Apple Photos Extend is only available in the temporary SIP-disabled research setup. Choose another expansion model for normal use.")
    lldb = subprocess.check_output(["/usr/bin/xcrun","--find","lldb"],text=True).strip()
    if not os.access(lldb,os.X_OK): raise RuntimeError("Xcode's LLDB debugger is unavailable.")
    return {"schema":1,"backend":"Apple Photos Extend", "os_build":subprocess.check_output(["/usr/bin/sw_vers","-buildVersion"],text=True).strip(),
            "helpers_sha256":{p.name:sha(p) for p in files},"lldb":lldb}


def photos_pid():
    output = subprocess.check_output(["/bin/ps","-axo","pid=,comm="],text=True)
    matches = [int(line.strip().split(None,1)[0]) for line in output.splitlines()
               if len(line.strip().split(None,1)) == 2 and line.strip().split(None,1)[1] == PHOTOS]
    if len(matches) != 1:
        raise RuntimeError("Open the original Apple Photos app, finish any edit, then restart the slideshow.")
    return matches[0]


def cached(cache, key):
    try:
        report = read_json(cache/"expansion.json")
        image = cache/"expanded.png"
        if report.get("status") != "complete" or report.get("cache_key") != key or not image.is_file(): return None
        if report.get("output_sha256") != sha(image) or report.get("output_size") != png_size(image): return None
        return report
    except (OSError,ValueError,RuntimeError,struct.error):
        return None


def publish(cache, output, report):
    output.mkdir(parents=True,exist_ok=True)
    if any((output/name).exists() for name in ("expanded.png","expansion.json")):
        raise RuntimeError("Expansion output already exists; refusing to overwrite it.")
    shutil.copyfile(cache/"expanded.png",output/"expanded.png")
    write_json(output/"expansion.json",report)


def wait_previous(active):
    record = read_json(active)
    if not record: return
    previous = Path(record.get("job", "")).resolve()
    if JOBS.resolve() not in previous.parents: raise RuntimeError("Invalid native Extend job record.")
    started = time.monotonic()
    while read_json(previous/"result.json").get("status") not in ("failed","complete"):
        check_cancel()
        if photos_pid() != record.get("pid"): return
        if time.monotonic()-started > 300:
            raise RuntimeError("A previous Photos Extend request is still running. Finish or cancel it before starting another.")
        if time.monotonic()-started < 1: progress("Waiting for the previous Photos Extend request")
        time.sleep(.5)


def expand(args):
    global current_job, attach_started
    identity = check_runtime(args.prepare_helper)
    key = hashlib.sha256(json.dumps({"source":sha(args.input),"percent":args.percent,"identity":identity},sort_keys=True).encode()).hexdigest()
    root = Path(args.cache_root)
    root.mkdir(parents=True,exist_ok=True)
    cache = root/key
    report = cached(cache,key)
    if report:
        progress("Reusing cached Apple Photos Extend image")
        publish(cache,Path(args.output),report); return
    if os.environ.get("SPATIAL_NATIVE_EXTEND_CACHE_ONLY") == "1":
        raise RuntimeError("No matching cached Apple Photos Extend image.")
    JOBS.mkdir(parents=True,exist_ok=True)
    with (JOBS/"request.lock").open("a") as lock:
        started = time.monotonic()
        while True:
            check_cancel()
            try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB); break
            except BlockingIOError:
                if time.monotonic()-started > 300: raise RuntimeError("Another Apple Photos Extend request is still running.")
                time.sleep(.2)
        report = cached(cache,key)
        if report: publish(cache,Path(args.output),report); return
        active = JOBS/"active-job.json"
        wait_previous(active)
        pid = photos_pid()
        check_cancel()
        current_job = JOBS/str(uuid.uuid4())
        current_job.mkdir(mode=0o700)
        progress("Preparing a full-quality photo for Apple Photos Extend")
        subprocess.run([args.prepare_helper,args.input,str(current_job/"source"),"768"],check=True)
        original = current_job/"source/original-srgb.png"
        source_size = png_size(original)
        shutil.copyfile(original,current_job/"input.heic")
        write_json(current_job/"request.json",{"schema":1,"album":"Trip","control":False,
                   "sourceSHA256":sha(current_job/"input.heic"),"percentPerEdge":args.percent})
        write_json(active,{"job":str(current_job),"pid":pid})
        check_cancel()
        progress("Requesting Apple Photos Extend")
        # LLDB parses these as commands, not shell text. JSON quoting preserves
        # spaces; generated job paths cannot contain control characters.
        commands = ["command script import "+json.dumps(str(HERE/"attach_jit.py")),
                    "spatial-extend-jit-queue "+str(pid)+" "+json.dumps(str(current_job))]
        with (current_job/"debugger.log").open("w") as log:
            attach_started = True
            child = subprocess.run([identity["lldb"],"--batch","-o",commands[0],"-o",commands[1]],stdout=log,stderr=log,timeout=60,
                                   env={**os.environ,"PYTHONDONTWRITEBYTECODE":"1"})
        attach = read_json(current_job/"jit-attach-result.json")
        if child.returncode or attach.get("stage") != "queued" or not attach.get("detached"):
            detail = attach.get("error", "See the native Extend debugger log.")
            if not (current_job/"result.json").exists():
                write_json(current_job/"result.json",{"status":"failed","message":detail})
            raise RuntimeError("Could not start native Photos Extend: "+detail)
        start = time.monotonic()
        next_update = start
        while True:
            check_cancel()
            report = read_json(current_job/"result.json")
            if report.get("status") == "complete": break
            if report.get("status") == "failed": raise RuntimeError(report.get("message","Apple Photos Extend failed."))
            if photos_pid() != pid: raise RuntimeError("Photos closed before Extend finished.")
            elapsed = time.monotonic()-start
            if elapsed > 310:
                (current_job/"cancel").touch()
                raise RuntimeError("Apple Photos Extend timed out after five minutes; cancellation was requested. Previously prepared photos remain available.")
            if time.monotonic() >= next_update:
                progress("Apple Photos Extend is generating · %ds" % elapsed)
                next_update = time.monotonic()+5
            time.sleep(.25)
        check_cancel()
        padding = [int(report[k]) for k in ("left","right","top","bottom")]
        expected = [source_size[0]+padding[0]+padding[1],source_size[1]+padding[2]+padding[3]]
        if png_size(current_job/"expanded.png") != expected: raise RuntimeError("Native Extend output dimensions do not match the request.")
        staging = Path(tempfile.mkdtemp(prefix=".native-",dir=root))
        try:
            progress("Restoring the original photo and saving the expanded image")
            subprocess.run([args.prepare_helper,"--restore",str(original),str(current_job/"expanded.png"),str(staging/"expanded.png"),str(padding[0]),str(padding[2])],check=True)
            metadata = {"schema":1,"status":"complete","backend":"Apple Photos Extend","cache_key":key,
                "percent_per_edge":args.percent,"source_size":source_size,"output_size":expected,
                "original_box_top_left":[padding[0],padding[2],*source_size],
                "original_box_bottom_left":[padding[0],padding[3],*source_size],
                "preserved_box_top_left":[padding[0],padding[2],*source_size],"padding_lrtb":padding,
                "output_color_space":"sRGB","orientation_applied":True,"preservation":"Full-resolution SDR sRGB original composited over native Extend output",
                "output_sha256":sha(staging/"expanded.png"),"native_seconds":report.get("elapsedSeconds"),"identity":identity}
            write_json(staging/"expansion.json",metadata)
            if cache.exists():
                # Only a corrupt/incomplete cache for this exact key is replaced.
                shutil.rmtree(cache)
            os.replace(staging,cache)
            publish(cache,Path(args.output),metadata)
            # Our disposable copies are redundant after verified cache publication.
            for name in ("input.heic","expanded.png"):
                (current_job/name).unlink(missing_ok=True)
            shutil.rmtree(current_job/"source")
        finally:
            if staging.exists(): shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input",nargs="?")
    parser.add_argument("output",nargs="?")
    parser.add_argument("percent",type=int,nargs="?")
    parser.add_argument("--check",action="store_true")
    parser.add_argument("--prepare-helper",required=True)
    parser.add_argument("--cache-root",default=str(SUPPORT/"Expanded Photos/Apple Photos Extend"))
    args = parser.parse_args()
    if args.check:
        print(json.dumps(check_runtime(args.prepare_helper),sort_keys=True)); return
    if not args.input or not args.output or args.percent is None or not 1 <= args.percent <= 20:
        parser.error("Expected INPUT OUTPUT PERCENT (1...20)")
    signal.signal(signal.SIGTERM,interrupted)
    signal.signal(signal.SIGINT,interrupted)
    expand(args)


if __name__ == "__main__":
    try: main()
    except Exception as error:
        print("ERROR: "+str(error),file=sys.stderr,flush=True)
        sys.exit(1)
