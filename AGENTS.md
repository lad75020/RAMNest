# Project Agent Guide

## Operating model
- Keep the active Spec Kit feature as the delivery source of truth.
- Resolve `.specify/feature.json` and use its `feature_directory` before acting on a feature.
- Read that feature's `spec.md`, `plan.md`, and `tasks.md`; also read `research.md`, `data-model.md`, `contracts/`, and `quickstart.md` when present.

## Skill routing
- Use `speckit-specify`, `speckit-clarify`, `speckit-plan`, and `speckit-tasks` to define, refine, plan, and schedule work.
- Use `speckit-implement` to execute `tasks.md` in order. Do not mark a task complete until its required verification passes.
- Use `speckit-gstack-bridge` for GStack plan/product/engineering/design reviews, code review, web QA, iOS QA, visual design review, release readiness, or deployment checks. Give it the active Spec Kit artifact context.
- For iOS device or cloud QA, confirm the target platform and required access before connecting.
- Treat GStack findings as evidence, not a competing specification. Reconcile approved scope changes into `spec.md`/`plan.md`, remediation work into `tasks.md`, and verified test evidence into `quickstart.md` or the project's QA record.
- Do not use a generated GStack plan to replace the active Spec Kit contract, and do not close tasks solely because a GStack report was produced.

## Jev decision support
- Use `jev_evaluate` only when a task needs a finite semantic judgment that code or direct evidence cannot reliably settle—for example, routing an ambiguous request, ranking clearly defined alternatives, or checking a claim against supplied evidence.
- Put the relevant evidence in `state`. Ask one narrow `noul`, `choice`, or bounded `score` question per judgment; include a no-match option when appropriate.
- Use it at a meaningful decision point, not on every turn. Skip deterministic checks, arithmetic, routine low-stakes choices, and open-ended writing.
- Treat the result and its confidence as advisory. Verify important conclusions against source evidence; keep authorization, approval, thresholds, calculations, and side effects under project policy and code.
- If the tool is unavailable or uncertain, continue with explicit reasoning or request review. Never silently treat a missing Jev result as approval.
- Send no credentials or unnecessary private project data. Calls may incur provider usage.

## Guardrails
- Follow the repository's local architecture, security, and test instructions in this file.
- Make the smallest justified change, run the relevant checks, and report the evidence.
