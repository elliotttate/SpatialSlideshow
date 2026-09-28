"""LLDB command to start one prepared job, then detach from original Photos.

Only explicitly run after checking current SIP status and Photos availability.
The command does not change signing, security policy, or files in Photos.app.
"""
import hashlib
import json
import shlex
import subprocess
from pathlib import Path

import lldb


def start(debugger, command, result, internal_dict):
    process = None
    job = None
    evidence = {"stage": "preflight"}
    try:
        args = shlex.split(command)
        if len(args) != 2:
            raise ValueError("Usage: spatial-extend-attach PID /absolute/prepared/job")
        pid = int(args[0])
        job = Path(args[1]).expanduser().resolve(strict=True)
        allowed = (Path.home() / "Library/Containers/com.apple.Photos/Data/Library/Caches/SpatialSlideshow-ExtendResearch").resolve()
        if not job.is_relative_to(allowed):
            raise ValueError("Expected an isolated Photos-container research job")
        request = json.loads((job / "request.json").read_text())
        if request.get("album") != "Trip" or request.get("control") is not False:
            raise ValueError("Expected a prepared Trip Photos-host job")
        if (job / "result.json").exists():
            raise ValueError("Job was already started; prepare a fresh job")
        bridge = job / "SpatialExtendBridge.dylib"
        if hashlib.sha256(bridge.read_bytes()).hexdigest() != request["bridgeSHA256"]:
            raise ValueError("Prepared bridge hash changed")
        sip = subprocess.run(["/usr/bin/csrutil", "status"], capture_output=True, text=True, check=True).stdout
        evidence["sip"] = sip.strip()
        if "System Integrity Protection status: disabled." not in sip:
            raise ValueError("SIP is enabled or has an unreviewed custom configuration; no attach attempted")
        executable = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True, check=True).stdout.strip()
        if executable != "/System/Applications/Photos.app/Contents/MacOS/Photos":
            raise ValueError("PID is not the original system Photos executable")

        debugger.SetAsync(False)
        target = debugger.CreateTarget(executable)
        error = lldb.SBError()
        evidence["stage"] = "attach"
        process = target.AttachToProcessWithID(debugger.GetListener(), pid, error)
        if error.Fail() or not process or not process.IsValid():
            raise RuntimeError(str(error))
        options = lldb.SBExpressionOptions()
        options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
        options.SetIgnoreBreakpoints(True)
        options.SetUnwindOnError(True)
        options.SetTimeoutInMicroSeconds(10_000_000)

        def evaluate(expression):
            value = target.EvaluateExpression(expression, options)
            if value.GetError().Fail():
                raise RuntimeError(str(value.GetError()))
            return value

        evidence["stage"] = "load-bridge"
        handle = evaluate(f"(void *)dlopen({json.dumps(str(bridge))}, 2)").GetValueAsUnsigned()
        if not handle:
            error_text = evaluate("(char *)dlerror()").GetSummary()
            raise RuntimeError(f"Photos rejected the bridge library: {error_text}")
        evidence["libraryLoaded"] = True
        symbol = evaluate(f'(void *)dlsym((void *){handle}, "SpatialExtendStart")').GetValueAsUnsigned()
        if not symbol:
            raise RuntimeError("Research entry point is missing")
        evidence["stage"] = "start-job"
        code = evaluate(f'(int)((int (*)(const char *))dlsym((void *){handle}, "SpatialExtendStart"))({json.dumps(str(job))})').GetValueAsSigned()
        evidence["entryReturnCode"] = code
        if code:
            raise RuntimeError(f"Research entry rejected request: {code}")
        evidence["stage"] = "queued"
        result.PutCString(f"Queued Trip job; detaching so Photos can run it. Status: {job / 'result.json'}")
    except Exception as error:
        evidence["error"] = str(error)
        result.SetError(str(error))
    finally:
        if process and process.IsValid() and process.GetState() not in (lldb.eStateDetached, lldb.eStateExited):
            detach = process.Detach()
            evidence["detached"] = detach.Success()
            if detach.Fail():
                result.SetError(f"Detach failed; inspect Photos process immediately: {detach}")
        if job is not None and job.is_dir():
            (job / "attach-result.json").write_text(json.dumps(evidence, indent=2) + "\n")


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -f attach_bridge.start spatial-extend-attach")
