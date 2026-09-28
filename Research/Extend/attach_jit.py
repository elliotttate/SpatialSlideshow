"""Explicit one-shot LLDB experiment using target expressions, not a dylib.

Use the owned control first. Photos mode requires the original process, disabled
SIP, a fresh Trip job, and its matching input hash. No security policy is changed.
"""
import hashlib
import json
import shlex
import shutil
import subprocess
import time
import uuid
from pathlib import Path

import lldb

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build/research/extend-bridge"
PHOTOS = "/System/Applications/Photos.app/Contents/MacOS/Photos"


def _run(debugger, command, result, internal_dict, control=False, queue_only=False):
    process = None
    job = None
    evidence = {"transport": "LLDB JIT", "control": control, "stage": "preflight"}
    try:
        args = shlex.split(command)
        if len(args) != (1 if control else 2):
            raise ValueError("Expected prepared-job path (control) or PID prepared-job path (Photos)")
        prepared = Path(args[-1]).resolve(strict=True)
        request = json.loads((prepared / "request.json").read_text())
        if request.get("album") != "Trip" or request.get("schema") != 1:
            raise ValueError("Expected a prepared Trip fixture")
        if hashlib.sha256((prepared / "input.heic").read_bytes()).hexdigest() != request["sourceSHA256"]:
            raise ValueError("Trip fixture hash mismatch")
        if control:
            job = BUILD / "controls" / str(uuid.uuid4())
            job.mkdir(parents=True, mode=0o700)
            shutil.copy2(prepared / "input.heic", job / "input.heic")
            request["control"] = True
            (job / "request.json").write_text(json.dumps(request, indent=2)+"\n")
            (BUILD / "last-jit-control-job.txt").write_text(str(job)+"\n")
            executable = str(BUILD / "SpatialExtendBridgeHost")
        else:
            job = prepared
            allowed = (Path.home()/"Library/Containers/com.apple.Photos/Data/Library/Caches/SpatialSlideshow-ExtendResearch").resolve()
            if not job.is_relative_to(allowed) or request.get("control") is not False:
                raise ValueError("Expected Photos-container job")
            if (job / "result.json").exists():
                raise ValueError("Job already started; prepare a fresh one")
            sip = subprocess.check_output(["/usr/bin/csrutil","status"],text=True).strip()
            evidence["sip"] = sip
            if sip != "System Integrity Protection status: disabled.":
                raise ValueError("SIP is enabled or uses an unreviewed custom configuration")
            pid = int(args[0])
            executable = subprocess.check_output(["/bin/ps","-p",str(pid),"-o","comm="],text=True).strip()
            if executable != PHOTOS:
                raise ValueError("PID is not original Photos")
        debugger.SetAsync(False)
        target = debugger.CreateTarget(executable)
        evidence["stage"] = "attach"
        if control:
            breakpoint = target.BreakpointCreateByName("main",Path(executable).name)
            process = target.LaunchSimple(["--jit-wait",str(job)],None,str(ROOT))
            breakpoint.SetEnabled(False)
        else:
            error = lldb.SBError()
            process = target.AttachToProcessWithID(debugger.GetListener(),pid,error)
            if error.Fail(): raise RuntimeError(str(error))
        if not process or not process.IsValid() or process.GetState() != lldb.eStateStopped:
            raise RuntimeError("Host did not stop for expression evaluation")
        options = lldb.SBExpressionOptions()
        options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
        options.SetIgnoreBreakpoints(True)
        options.SetUnwindOnError(True)
        options.SetTimeoutInMicroSeconds(15_000_000)
        source = Path(__file__).with_name("JITRequest.expr").read_text()
        evidence["expressionSHA256"] = hashlib.sha256(source.encode()).hexdigest()
        expression = source.replace("__JOB_JSON__",json.dumps(str(job))).replace("__CONTROL__","true" if control else "false")
        evidence["stage"] = "evaluate"
        value = target.EvaluateExpression(expression,options)
        if value.GetError().Fail(): raise RuntimeError(str(value.GetError()))
        if value.GetValueAsSigned(-1) != 0: raise RuntimeError("Unexpected expression return")
        if queue_only:
            evidence["stage"] = "queued"
            result.PutCString(f"Queued Trip job: {job}")
            return
        evidence["stage"] = "running"
        debugger.SetAsync(True)
        error = process.Continue()
        if error.Fail(): raise RuntimeError(str(error))
        print(f"Started JIT job: {job}",flush=True)
        started = time.monotonic()
        last_status = None
        cancellation_requested = False
        while True:
            path = job/"result.json"
            status = json.loads(path.read_text()) if path.exists() else {}
            if status.get("status") != last_status:
                last_status = status.get("status")
                print(json.dumps(status),flush=True)
            if last_status in ("failed","complete"):
                evidence["stage"] = "finished"
                evidence["result"] = status
                # Let the block return before releasing its debugger-owned code.
                time.sleep(1)
                break
            state = process.GetState()
            if state == lldb.eStateStopped:
                reasons = [t.GetStopDescription(1024) or "" for t in process
                           if t.GetStopReason() not in (lldb.eStopReasonNone,lldb.eStopReasonInvalid)]
                if reasons and all("EXC_RESOURCE" in r and "high watermark memory limit" in r for r in reasons):
                    evidence.setdefault("resourceWarnings",[]).extend(reasons)
                    error = process.Continue()
                    if error.Fail(): raise RuntimeError(str(error))
                    continue
            if state in (lldb.eStateExited,lldb.eStateCrashed,lldb.eStateStopped):
                raise RuntimeError(f"Host stopped unexpectedly in state {state}; inspect LLDB")
            if time.monotonic()-started > 300 and not cancellation_requested:
                (job/"cancel").touch()
                cancellation_requested = True
                print("Requested cooperative cancellation; retaining debugger until request returns.",flush=True)
            time.sleep(.5)
        result.PutCString(f"Result: {job/'result.json'}")
    except Exception as error:
        evidence["error"] = str(error)
        result.SetError(str(error))
    finally:
        if process and process.IsValid() and process.GetState() not in (lldb.eStateDetached,lldb.eStateExited):
            if control:
                evidence["ownedHostTerminated"] = process.Kill().Success()
            else:
                if process.GetState() == lldb.eStateRunning:
                    process.Stop()
                evidence["detached"] = process.Detach().Success()
        if job and job.is_dir():
            (job/"jit-attach-result.json").write_text(json.dumps(evidence,indent=2)+"\n")


def control(debugger, command, result, internal_dict):
    _run(debugger,command,result,internal_dict,control=True)


def photos(debugger, command, result, internal_dict):
    _run(debugger,command,result,internal_dict,control=False)


def queue(debugger, command, result, internal_dict):
    # Target allocations for a persistent expression survive debugger detach.
    # The caller polls result.json, keeping Photos free of debugger stop events.
    _run(debugger,command,result,internal_dict,control=False,queue_only=True)


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -f attach_jit.photos spatial-extend-jit")
    debugger.HandleCommand("command script add -f attach_jit.queue spatial-extend-jit-queue")
    debugger.HandleCommand("command script add -f attach_jit.control spatial-extend-jit-control")
