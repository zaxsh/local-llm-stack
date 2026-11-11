# docs

Four documents, written while the work happened rather than after. The README is the tour; these
are the receipts.

| file | what it is | read it if |
|---|---|---|
| [`local-llm-report.md`](local-llm-report.md) | The results: every model, every setting, tokens/sec, time to first token, context ceilings, plus the raw answers that were used to judge quality. 36 KB. | you want the numbers |
| [`how-the-numbers-were-made.md`](how-the-numbers-were-made.md) | The method, and the mistakes: what was measured how, which conclusions were wrong at first (the GPU was powered off, KV-cache arithmetic double-counted, estimation replaced by trial loads), and why each correction was forced. 31 KB. | you want to trust or reproduce the numbers |
| [`PROJECT-CONTEXT.md`](PROJECT-CONTEXT.md) | The condensed state of the project: hardware, the serving contract, ports and aliases, what is on disk, house rules learned the hard way, and where the repository lives. | you are picking this up cold, or you are a future session |
| [`connecting-local-models.md`](connecting-local-models.md) | Wiring the server into Claude Code, dsh-tui, Cline, Continue, Aider, anything OpenAI-compatible, including the Anthropic-vs-OpenAI endpoint difference. | you want an agent to use the model |

Two habits run through all four: no number appears without the command that produced it, and every
retracted claim stays visible with a note saying what replaced it.
