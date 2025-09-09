#!/usr/bin/env python3
"""
PREM-on-FHIR: one CLI to seed synthetic data & talk to HAPI.

Subcommands (short list):
  synthea build                 Build the Synthea Docker image
  synthea run                   Run Synthea and write NDJSON to output/
  fhir wait-ready               Wait until HAPI answers 200 on /metadata
  fhir import                   Submit + poll a bulk $import job
  fhir post-bundle              POST a single Bundle JSON
  fhir post-bundles             POST many Bundle JSON files by pattern
  bundle make-questionnaires    Build a transaction Bundle from CS/VS/Q JSON
  qr export-headers             Export QR header CSV from the HAPI DB (SQL)
  qr make-bundles               Generate QR batch bundles (NREQ/PPNQ dry-run)

The CLI auto-loads your root .env (or ENV_FILE), so you don’t have to
pass env values to every command.

Keep it simple:
- No external AI calls, only deterministic local generation.
- No Docker SDK requirement: we exec `docker` via subprocess.

Author: you + future-you – comments explain intent, not the obvious.
"""
from __future__ import annotations

import os, json, time, random, argparse
from pathlib import Path

from .utils import load_env_from_root, die, _vprint, env_bool
from .constants import DEFAULT_BASE, NREQ_Q, PPNQ_Q
from .bundle_build import cmd_make_questionnaires
from .wait_ready import cmd_wait_ready
from .import_bulk import cmd_import
from .post_bundles import cmd_post_bundle, cmd_post_bundles
from .qr_common import _read_header_csv, _qr_from_header, _bundle_entries
from .nreq import _nreq_answers, _parse_likert_dist
from .ppnq import _ppnq_answers_llm, _ppnq_answers_dry, LLM_STATS

def main() -> int:
    load_env_from_root()
    p = argparse.ArgumentParser(prog="cli", description="PREM-on-FHIR helper CLI")
    sub = p.add_subparsers(dest="cmd", required=True)

    # synthea
    from .docker_utils import check_docker, run_cmd
    psb = sub.add_parser("synthea", help="Synthea utilities")
    ssub = psb.add_subparsers(dest="scmd", required=True)

    def cmd_synthea_build(args):
        check_docker()
        context = Path(args.context).resolve()
        context.is_dir() or die(f"Build context not found: {context}", 2)
        cmd = ["docker","build","-t",args.tag,str(context)]
        return run_cmd(cmd)

    def cmd_synthea_run(args):
        check_docker()
        image = args.image
        out_dir = Path(args.output).resolve()
        out_dir.mkdir(parents=True, exist_ok=True)
        envs = {
            "POPULATION": args.population,
            "AGE_RANGE": args.age_range,
            "KEEP_FILE": args.keep_file,
            "EXTRA_ARGS": args.extra_args or "",
        }
        cmd = ["docker","run","--rm","-it","-v",f"{str(out_dir)}:/output"]
        for k,v in envs.items():
            if v is not None:
                cmd += ["-e", f"{k}={v}"]
        cmd += [image]
        return run_cmd(cmd)

    pbuild = ssub.add_parser("build", help="Build Synthea Docker image")
    pbuild.add_argument("--context", default="01-data-generation/synthea")
    pbuild.add_argument("--tag", default="syntheadocker")
    pbuild.set_defaults(func=cmd_synthea_build)

    prun = ssub.add_parser("run", help="Run Synthea and write NDJSON into output directory")
    prun.add_argument("--image", default="syntheadocker")
    prun.add_argument("--output", default="01-data-generation/synthea/output")
    prun.add_argument("--population", default=os.getenv("POPULATION","5"))
    prun.add_argument("--age-range", default=os.getenv("AGE_RANGE","18-100"))
    prun.add_argument("--keep-file", default=os.getenv("KEEP_FILE","keep_neuro.json"))
    prun.add_argument("--extra-args", default=os.getenv("EXTRA_ARGS","--exporter.fhir.bulk_data=true --exporter.baseDirectory=/output --generate.only_alive_patients=true --generate.max_attempts_to_keep_patient=20000"))
    prun.set_defaults(func=cmd_synthea_run)

    # fhir
    pfhir = sub.add_parser("fhir", help="FHIR server actions")
    fsub = pfhir.add_subparsers(dest="fcmd", required=True)

    pready = fsub.add_parser("wait-ready", help="Wait for HAPI to respond 200")
    pready.add_argument("--base", default=os.getenv("FHIR_BASE", DEFAULT_BASE))
    pready.add_argument("--interval", type=int, default=3)
    pready.add_argument("--timeout", type=int, default=120)
    pready.set_defaults(func=cmd_wait_ready)

    pimp = fsub.add_parser("import", help="Submit + poll a bulk $import job")
    pimp.add_argument("params_file", help="Parameters JSON")
    pimp.add_argument("--base", default=os.getenv("FHIR_BASE", DEFAULT_BASE))
    pimp.add_argument("--interval", type=int, default=None)
    pimp.add_argument("--timeout-minutes", type=int, default=60)
    pimp.set_defaults(func=cmd_import)

    ppost1 = fsub.add_parser("post-bundle", help="POST a single FHIR Bundle (transaction/batch)")
    ppost1.add_argument("bundle_file")
    ppost1.add_argument("--base", default=os.getenv("FHIR_BASE", DEFAULT_BASE))
    ppost1.add_argument("--timeout", type=int, default=120)
    ppost1.add_argument("--log-dir", default=None)
    ppost1.set_defaults(func=cmd_post_bundle)

    ppostn = fsub.add_parser("post-bundles", help="POST many Bundle JSON files by glob pattern")
    ppostn.add_argument("--pattern", default="**/*_bundle*.json")
    ppostn.add_argument("--base", default=os.getenv("FHIR_BASE", DEFAULT_BASE))
    ppostn.add_argument("--timeout", type=int, default=600)
    ppostn.add_argument("--accept", action="store_true", default=True)
    ppostn.add_argument("--prefer-minimal", action="store_true", default=True)
    ppostn.add_argument("--log-dir", default="./curl-logs")
    ppostn.set_defaults(func=cmd_post_bundles)

    # bundle
    pb = sub.add_parser("bundle", help="Bundle utilities")
    bsub = pb.add_subparsers(dest="bcmd", required=True)
    pmq = bsub.add_parser("make-questionnaires", help="Make a transaction Bundle from CodeSystem/ValueSet/Questionnaire JSON files")
    pmq.add_argument("--indir", required=True)
    pmq.add_argument("--outfile", required=True)
    pmq.add_argument("--method", choices=["auto","put","post"], default="auto")
    pmq.set_defaults(func=cmd_make_questionnaires)

    # qr
    pqr = sub.add_parser("qr", help="QuestionnaireResponse helpers")
    qsub = pqr.add_subparsers(dest="qcmd", required=True)

    from .qr_common import cmd_qr_export_headers  # local import to avoid clutter
    pqrex = qsub.add_parser("export-headers", help="Run SQL against HAPI DB and write header CSV")
    pqrex.add_argument("--host", default=None)
    pqrex.add_argument("--port", default=None)
    pqrex.add_argument("--name", default=None)
    pqrex.add_argument("--user", default=None)
    pqrex.add_argument("--passwd", default=None)
    pqrex.add_argument("--sql", default=None)
    pqrex.add_argument("--outdir", default="03-elt/nlp_pipeline/input")
    pqrex.set_defaults(func=cmd_qr_export_headers)

    pqrmk = qsub.add_parser("make-bundles", help="Generate QR batch bundles (NREQ / PPNQ dry-run)")
    pqrmk.add_argument("--mode", choices=["nreq","ppnq"], required=True)
    pqrmk.add_argument("--csv", required=True)
    pqrmk.add_argument("--out", default="01-data-generation/synthea/output/qr")
    pqrmk.add_argument("--chunk-size", type=int, default=250)
    pqrmk.add_argument("--questionnaire-file", default=None)
    pqrmk.add_argument("--questionnaire-url", default=None)
    pqrmk.add_argument("--seed", type=int, default=None)
    pqrmk.add_argument("--likert-dist", default=None, help="NREQ only: probs for 1,2,3 e.g. 0.2,0.5,0.3")
    pqrmk.add_argument("--dry-run", action="store_true", help="PPNQ only: generate placeholder text (no LLM)")
    pqrmk.add_argument("--llm", action="store_true", help="PPNQ only: call OpenAI for text answers")
    pqrmk.add_argument("-v", "--verbose", action="store_true")

    # new knobs we added in the refactor
    pqrmk.add_argument("--nps-dist", default=None)
    pqrmk.add_argument("--keyword-rate", type=float, default=0.35)
    pqrmk.add_argument("--style-variance", type=float, default=0.7)

    # optional LLM tuning (env-backed defaults)
    pqrmk.add_argument("--llm-model", default=os.getenv("LLM_MODEL", "gpt-4o-mini"))
    pqrmk.add_argument("--llm-temperature", type=float, default=float(os.getenv("LLM_TEMPERATURE", "0.6")))
    pqrmk.add_argument("--llm-max-retries", type=int, default=int(os.getenv("LLM_MAX_RETRIES", "3")))

    def cmd_qr_make_bundles(args: argparse.Namespace) -> int:
        rng = random.Random(args.seed)
        header_rows = _read_header_csv(Path(args.csv))
        if not header_rows:
            die("No rows in header CSV.", 2)

        # choose questionnaire
        if args.mode == "nreq":
            questionnaire = json.loads(Path(args.questionnaire_file).read_text(encoding="utf-8")) if args.questionnaire_file else NREQ_Q
        else:
            questionnaire = json.loads(Path(args.questionnaire_file).read_text(encoding="utf-8")) if args.questionnaire_file else PPNQ_Q
        questionnaire_url = args.questionnaire_url or questionnaire.get("url")

        resources = []
        if args.mode == "nreq":
            probs = _parse_likert_dist(args.likert_dist)
            for row in header_rows:
                answers = _nreq_answers(rng, questionnaire, probs)
                resources.append(_qr_from_header(args.mode, row, questionnaire, questionnaire_url, answers))
        else:
            total = len(header_rows); started = time.perf_counter()
            for idx, row in enumerate(header_rows, start=1):
                if args.llm and not args.dry_run:
                    _vprint(args.verbose, f"[{idx}/{total}] Generating answers via LLM …")
                    answers = _ppnq_answers_llm(
                        questionnaire, row,
                        model=args.llm_model,
                        temperature=args.llm_temperature,
                        max_retries=args.llm_max_retries,
                        verbose=args.verbose,
                        row_index=idx,
                        total_rows=total,
                        nps_dist_arg=args.nps_dist,
                        keyword_rate=args.keyword_rate,
                        style_variance=args.style_variance,
                    )
                else:
                    _vprint(args.verbose, f"[{idx}/{total}] Dry-run text generation …")
                    answers = _ppnq_answers_dry(rng)
                resources.append(_qr_from_header(args.mode, row, questionnaire, questionnaire_url, answers))

            if args.verbose:
                elapsed = time.perf_counter() - started
                _vprint(args.verbose, f"… finished {total} rows in {elapsed:.1f}s "
                                      f"(LLM calls={LLM_STATS['calls']}, successes={LLM_STATS['successes']}, retries={LLM_STATS['retries']})")

        # write chunked bundles
        out_dir = Path(args.out); out_dir.mkdir(parents=True, exist_ok=True)
        total = len(resources); chunk = max(1, args.chunk_size)
        files = []
        for i in range((total + chunk - 1) // chunk):
            batch = resources[i*chunk:(i+1)*chunk]
            bundle = _bundle_entries(batch)
            p = out_dir / f"{args.mode}_batch_bundle_{i+1:03d}.json"
            p.write_text(json.dumps(bundle, indent=2), encoding="utf-8"); files.append(p)
        print(f"Created {total} QuestionnaireResponses in {len(files)} file(s):")
        for pth in files: print(f" - {pth}")

        if args.verbose and args.mode == "ppnq":
            print("\nLLM summary:")
            print(f"  calls     : {LLM_STATS['calls']}")
            print(f"  successes : {LLM_STATS['successes']}")
            print(f"  retries   : {LLM_STATS['retries']}")
            if LLM_STATS["total_tokens"]:
                print(f"  tokens    : {LLM_STATS['total_tokens']}")
        return 0

    pqrmk.set_defaults(func=cmd_qr_make_bundles)

    args = p.parse_args()
    return args.func(args)
