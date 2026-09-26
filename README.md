# queries-that-quietly-fell-back

A Power BI semantic model in **Direct Lake** storage mode, serving a table that
is not running in Direct Lake mode — correct answers, no error, and every piece
of metadata you would check still saying `DirectLake`.

## The problem

Direct Lake is the reason to put a semantic model on Fabric. Queries are answered
by the VertiPaq engine straight from Parquet in OneLake, so you get Import-mode
speed without an Import-mode refresh. That is the whole pitch.

A Direct Lake table stops being a Direct Lake table under several ordinary
conditions — it was built on a SQL view, it was created by a pipeline and never
framed, it outgrew a capacity guardrail. When that happens, `DirectLakeBehavior`
decides what you find out about it. It defaults to `Automatic`, which means the
query **silently** falls back to DirectQuery, federates to the SQL analytics
endpoint, and returns the right answer more slowly.

What makes this worth a lab is that **every signal a reviewer would check says
the deployment is fine**:

- *Did the query work?* Yes.
- *Are the numbers right?* Yes, to the penny.
- *Is the table in Direct Lake storage mode?* Yes — the metadata says so.
- *Did the refresh succeed?* Yes, as long as anything else in the model framed.

## What this proves

A real Fabric warehouse, six semantic models, and expectations declared in
[`fallback-matrix.json`](fallback-matrix.json) before the run.

| pass | `directLakeBehavior` | |
|---|---|---|
| `automatic` | `automatic` | the default, and what the documentation recommends for production |
| `directLakeOnly` | `directLakeOnly` | the remediation: the same condition becomes an error |

| | |
|---|---|
| Guards | 3, each graded in both passes |
| Assertions about the signals people check | 5 |
| Declared in | [`fallback-matrix.json`](fallback-matrix.json), written before the run |
| Unit tests | 42, no Fabric environment required |
| Cost | nothing — a Fabric trial capacity |

The three guards are one framed table (the control), **the same table before the
model was framed**, and a table over an unmaterialised SQL view. The first two
being the identical table in the identical model is deliberate: it leaves framing
as the only difference between them, so the table itself cannot be the
explanation.

## The result

```
== automatic / clean
   beforeFraming Sales      query=True fallbackInfo="Not Framed" storageMode=DirectLake
   framing: Completed
   afterFraming  Sales      query=True fallbackInfo=null         storageMode=DirectLake

== automatic / view
   beforeFraming SalesView  query=True fallbackInfo="Not Framed" storageMode=DirectLake
   framing: Completed
   afterFraming  SalesView  query=True fallbackInfo="View"       storageMode=DirectLake

== automatic / mixed
   framing: Completed
   afterFraming  Sales      query=True fallbackInfo=null         storageMode=DirectLake
   afterFraming  SalesView  query=True fallbackInfo="View"       storageMode=DirectLake

== directLakeOnly / clean
   beforeFraming Sales      query=False  <- refused
   framing: Completed
   afterFraming  Sales      query=True fallbackInfo=null         storageMode=DirectLake

== directLakeOnly / view
   framing: Failed  ModelRefresh_ShortMessage_ProcessingError
   afterFraming  SalesView  query=False  <- refused

11/11 as declared; 0 failed; 0 inconclusive.
```

**Read the `automatic` block as a whole.** Every query succeeded. Every table
reported `storageMode=DirectLake`. Every refresh reported `Completed`. And one of
those tables was federated to SQL on every single query, which you can only tell
from a column the documentation describes incorrectly.

Then read the `directLakeOnly` block. The same conditions, the same data, and now
they are errors — a refused query before framing, and a refresh that fails outright
on the view-backed model and names the table it could not use.

That is the finding: one property, defaulting to the quiet setting, separates a
deployment that works from one that reports working.

## Why the evidence has to be `TABLETRAITS()`

`Resolve-FallbackOutcome` grades on three separate inputs — whether the query
succeeded, whether `EVALUATE TABLETRAITS()` returned a `DirectLakeFallbackInfo`
column, and what was in it — and it deliberately does **not** treat a successful
query as evidence of anything:

| outcome | meaning |
|---|---|
| `DirectLake` | the table ran in Direct Lake mode |
| `FellBack` | the query succeeded and the table was federated to SQL |
| `Refused` | the query failed *because* fallback was not permitted |
| `Unknown` | could not be determined. Always a failure, never a pass |

Silent fallback **is** a successful query returning correct results. A function
that took success as evidence would be structurally incapable of seeing the thing
this lab is about.

All of that judgement lives in
[`DirectLakeMode`](module/DirectLakeMode/DirectLakeMode.psm1), which makes no
call to Fabric and is covered by 42 unit tests.

## The four ways you would try to notice, and why none work

**The query succeeds.** In every measurement in the default pass. No error, no
warning, no non-zero status, so a pipeline gating on "did the DAX query work"
learns nothing.

**The numbers are correct.** The federated table returns exactly what the framed
one returns. This is why nobody notices: the report is right, and stays right
while being slower and more expensive than the thing it was designed to be.

**The storage mode still says `DirectLake`.** `TABLETRAITS()` reports
`StorageMode=DirectLake` for a table whose every query is being federated, in
every state measured. Storage mode is a model property; fallback is a runtime
decision. The metadata a reviewer would open cannot distinguish them.

**The refresh reports success.** This is the worst of the four. A model holding
one framable table and one view-backed table reports its refresh as `Completed`,
because *something* in it framed — while the view-backed table did not, and
still reports a fallback reason afterwards. The refresh status is a function of
model composition, not of whether every table actually landed.

## Where the documentation and the API disagree

The docs state that a `DirectLakeFallbackInfo` value of `None` means the table is
using Direct Lake mode. Measured against a real framed table, the value is
**`null`**.

That is not pedantry, it is the load-bearing detail of the whole grader. `null`
is also exactly what an unreadable column looks like — so a grader handed only
the value has two choices, both wrong: fail every healthy table, or pass every
failed measurement. The drill therefore records whether the column was *present*
separately from what was *in* it, and that is the only reason the healthy case
can be graded at all.

The reasons actually observed are `"Not Framed"` and `"View"`.

## The part that only shows up in CI

Everything above was measured twice: once from a laptop as a signed-in user, and
once from GitHub Actions as a federated service principal. The first worked. The
second reported **eleven inconclusive results**, because a Direct Lake semantic
model owned by a service principal cannot frame at all under the default
configuration.

The error is `We cannot access the source Delta table 'Sales'`, on a warehouse
the service principal had just created itself, with Admin on the workspace, after
successfully running `CREATE TABLE`, `INSERT` and `CREATE VIEW` against it
seconds earlier. Nothing in that message is about identity.

The cause is single sign-on. By default a Direct Lake model resolves data access
through the identity of whoever is querying, and a service principal running
unattended is not an interactive identity to borrow. The documentation says so,
in one clause of one sentence: service principals are supported, *"but the
default Direct Lake semantic models on lakehouse/warehouse don't support this
scenario"*. The fix is to bind the model to a cloud connection with a **fixed
identity**.

Three things about that were not in any documentation I could find:

**`gatewayObjectId` takes the connection id.** The documented route is
`Default.BindToGateway`, and for this dataset `Default.DiscoverGateways` returns
an empty list while the datasource carries no gateway id at all — so the route
looks inapplicable. Fabric models a cloud connection as a virtual gateway
cluster, so passing the connection's own id works. `HTTP 200`, and the model
frames immediately afterwards.

**Workspace Admin is not enough to use a connection.** Connections carry their
own role assignments. Binding a model to one the orchestrator cannot use fails
later, at framing, rather than at bind time.

**The fixed identity does not have to be a secret.** A service principal
credential on the connection would mean a client secret to store and rotate.
A **workspace identity** is a supported authentication method for these
connections, so there is no secret anywhere in this design — and the connection
is created with `skipTestConnection` false, which means Fabric verified the
identity really can read the warehouse before the drill ever ran.

The cost of all this is that the warehouse became persistent setup: a connection
is bound to one specific server *and* database, so it cannot be created ahead of
a warehouse that does not exist yet. The drill therefore creates and destroys
only the semantic models — which are the thing under test anyway — and verifies
the fixture on every run, because state this drill does not own is exactly the
kind of thing it exists to be suspicious of.

## Cost

**Nothing.** A Fabric trial capacity, which is `FTL4` and lasts 60 days.

Being straight about what that means: Microsoft Fabric has **no free tier**. The
per-user "Fabric (Free)" licence grants no compute — it only lets you create
Fabric items in a workspace that is already backed by a capacity. So the options
are a 60-day trial or an F capacity, and the trial behind this lab expires.

The drill takes the workspace as a parameter for exactly that reason. Anyone
reading this can point it at their own trial, or at an **F2 at $0.36/hour**
(measured from the Azure retail price API: $0.18 per capacity-unit-hour × 2),
billed per second with a one-minute minimum and pausable. A full drill run is a
few minutes, so under a dollar. Watch the `Capacity Overage` meter if you scale
the fixture up — it bills at **$0.54 per CU-hour, three times the base rate**.

## Running it

```bash
scripts/bootstrap.sh --workspace lab-directlake-fallback --capacity <trial-capacity-name>
gh workflow run drill.yml
```

The bootstrap creates everything the drill does not own and is re-runnable: a
workspace identity, the warehouse, a cloud connection bound to it with that
identity fixed, a federated Entra application, **Admin** on the workspace and
**User** on the connection, and the repository variables and secrets.

Admin rather than Member is not convenience: the drill creates a warehouse and
six semantic models and deletes them again, and Member cannot delete items it did
not create. Without the delete, a second run inherits the first run's state and a
guard passes for the wrong reason.

The workspace is created once, by a human, and reused. The drill only creates
items *inside* it. That split means the tenant setting *"Service principals can
create workspaces, connections, and deployment pipelines"* can stay off — there
is no reason to grant a lab orchestrator that when a workspace role is enough.
The setting it does need is the separate *"Service principals can call Fabric
public APIs"*, and `bootstrap.sh` checks for it rather than letting the drill
discover it as a 401.

Locally, with PowerShell 7 and the Azure CLI:

```bash
pwsh ./scripts/Invoke-FallbackDrill.ps1 \n  -WorkspaceId <guid> -WarehouseId <guid> -ConnectionId <guid>
```

If the machine has no PowerShell 7 — the one this was written on has 5.1 only —
[`dev/controller.Dockerfile`](dev/controller.Dockerfile) builds one. Pass the
three tokens in from the host; the header of that file explains why they are not
fetched inside the container.

## Bugs the build found in itself

**The premise was wrong, and reading the docs first caught it.** This lab was
going to be about a Direct Lake model serving stale data after its Delta table
changed. The setting that governs that, *"Keep your Direct Lake data up to
date"*, is **enabled by default** — so staleness needs somebody to have turned it
off, which is a story about a flipped switch rather than a trap anyone can fall
into. The subject moved to fallback, which is silent by default.

**The grader failed a perfectly healthy table.** Because the docs promise `None`
and the API returns `null`, and `null` was already the module's signal for "not
measured". Two contradictory meanings on one value. Fixed by carrying column
presence separately — see above. Caught by running the drill, not by reading the
module.

**A view-backed table took the control down with it.** The first design put both
tables in one model. Under `directLakeOnly` that model cannot be refreshed at
all — framing a view fails, because a view has no Delta table — so the framed
table never framed either and the baseline became collateral damage instead of a
control. The view-backed table now lives in its own model, and the matrix refuses
a configuration where the baseline and the unframed guard drift onto different
tables or models.

**An assertion was declared, failed, corrected, and then withdrawn.** It claimed
the refresh fails under `directLakeOnly` and completes under the default. The
drill reported it `FAILED`: framing a view-only model failed under *both*. On the
very next run, identical code, the default reported `Completed`. Two different
answers to the same question, so it is recorded under `knownNonDeterminism` in
the matrix rather than asserted — a flaky expectation would make the whole drill
untrustworthy, and a lab that fails half the time teaches nobody anything. What
*is* asserted is the half that has been stable on every run.

**`System.Data.SqlClient` does not exist on PowerShell 7 on Linux.** The drill
runs T-SQL, and the Windows approach — `New-Object
System.Data.SqlClient.SqlConnection` with an `AccessToken` property — is a .NET
Framework assembly. It worked on the development machine and would have failed on
the runner. The `SqlServer` module's `Invoke-Sqlcmd -AccessToken` is the
cross-platform path, and the controller image asserts that parameter exists at
**build** time rather than ten minutes into a run.

**PSScriptAnalyzer threw on its first path-based invocation.** *"Object reference
not set to an instance of an object"*, then worked on every call after. Third lab
in this series to hit it. CI scans a snippet with two known violations first,
which both absorbs the warm-up and proves the analyzer still catches what it
should — a crashed analyzer reports zero findings, which reads exactly like clean
code.

**The drill passed on a laptop and reported eleven inconclusive results in CI.**
Because a service-principal-owned Direct Lake model cannot frame under default
single sign-on, which no amount of local testing as a signed-in user would ever
have shown. See [The part that only shows up in CI](#the-part-that-only-shows-up-in-ci).
Worth saying what went right: the drill graded that run `Unknown` everywhere it
could not measure, never a false pass, and exited non-zero. The tooling was
correct and the environment was not, which is the outcome the design was for.

**And the check on that run was wrong in the most embarrassing possible way.**
The CI drill was reported here as having "exited 0 despite failing" — a red run
coming back green, which would have been the worst bug in the repository. It was
not. `gh run view --exit-status` exits 1 correctly and the run's conclusion is
`failure`. The mistake was `gh run watch ... | tail -12; echo $?`, which reports
the exit status of `tail`. Three subsequent `grep` checks for stray line
continuations were wrong too: `'\\$'` matches every line containing a dollar
sign, so they all "found" problems that did not exist. A check nobody checks is
the subject of this entire series of labs, and it still took inverting the test —
searching for the character that *should* be there — to establish the files were
fine.

## What this does not do

**One fallback trigger family.** A SQL view and an unframed model. Exceeding a
capacity guardrail is the third documented cause and is not exercised, because
staging it needs a table large enough to matter and that is a different lab about
a different thing.

**It does not measure the performance cost.** Fallback is slower and consumes
more capacity, and quantifying that honestly needs a fixture big enough for the
difference to exceed the noise. Four rows proves the mode, not the penalty.

**Direct Lake on SQL, not Direct Lake on OneLake.** The newer option runs
`DirectLakeOnly` exclusively and has no fallback to be silent about, which is the
right default and also why it is not the subject here. If you are choosing today,
choose that — this lab is about what the existing, recommended default does.

**It does not touch report-level behaviour.** No Power BI report, no visuals. The
subject is what the semantic model does with a DAX query, and a report would add
a rendering layer between the finding and the evidence.
