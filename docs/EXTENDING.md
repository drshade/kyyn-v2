# Extending the baseline

The baseline intentionally covers only the common software change lifecycle.
A project may add specialist practices when its product, customer or operating
environment makes them useful.

An extension should state:

1. when it applies;
2. what additional evidence, verification or review it requires;
3. where its authoritative instructions live;
4. who may make any decisions it introduces; and
5. how it composes with Issues, ADRs, PRs and the project gate.

Extensions should add to the lifecycle rather than duplicate it. For example,
an extension may require an additional review before a qualifying PR merges,
or add a check to the project gate. It should not create another backlog for
the same work or another document that competes with the governing ADR.

Keep an extension outside the baseline until a real project needs it. The
existence of a possible practice is not itself a reason to make every project
carry it.
