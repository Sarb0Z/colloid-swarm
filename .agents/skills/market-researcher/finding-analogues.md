# Finding analogues outside the segment

The best implementation of a mechanic is usually not in your market. Competitors copy each other, so a segment converges on a local optimum. The global one is wherever that mechanic *is* the business.

Each mechanic below carries **two deliberately dissimilar implementers**, because a single named example per mechanic reads as the answer rather than the category:

| Mechanic | Consumer-software instance | Structurally unlike it |
|---|---|---|
| Streaks and progression | Duolingo | Physiotherapy adherence programmes, where the same problem is clinical and nobody gamifies it |
| Reverse bidding | Upwork | Construction tendering and freight brokerage — offline-rooted, high-value, slow |
| Cold-start liquidity | Uber | Commodity exchanges, solved with designated market makers rather than subsidy |
| Trust between strangers | Wise | Property conveyancing, solved with escrow and a regulated intermediary |

The right-hand column is the point. Two instances that share a market and a business model teach the market; two that share only the *mechanic* teach the mechanic. When looking for an analogue, aim for the right-hand column — the further instance is usually where the mechanic is most exposed, because it had to work without the surrounding conveniences of a consumer app.

These are illustrations of the move, not a shortlist to go read. If the mechanic in front of you is not one of these four, the table has done its job by showing what a pair looks like.

Searching only in-segment produces a product that matches its competitors and beats nobody.

## Decompose to the mechanic first

The search cannot start from the feature name; it has to start from the abstract job. Restate it until no domain noun is left.

| Feature | Mechanic | Who else has this problem |
|---|---|---|
| XP for logged workouts | Progress feedback sustaining a voluntary repeated behaviour whose real reward is delayed and invisible | Language learning, savings apps, meditation, games, loyalty schemes |
| Reverse bidding on jobs | Sellers compete for a buyer's posted brief under information asymmetry | Freelance marketplaces, freight, construction tenders, ad exchanges |
| Equipment photo scanning | Turning an ambiguous real-world object into a catalogue entry with one tap | Plant and bird ID, receipt scanning, barcode-less checkout, wine labels |

Once the mechanic is stated without industry nouns, the candidate list writes itself.

**Do this before searching, not after.** Stating the abstract structure first is what stops the search from being captured by surface resemblance — matching on "it is also a fitness app" instead of "it also sustains a voluntary repeated behaviour whose reward is delayed". Surface capture is the documented default failure in machine analogy-making, and the decomposition step is the guard against it. A candidate list produced before the mechanic is stated is a list of things that merely look alike.

**Then check the spread.** Naming examples narrows the field the search draws from — pairing each mechanic with a dissimilar case widens it measurably, but only partly; the pull toward the illustrated domains survives the pairing. So audit the output, not just the input: if every candidate landed in one industry, or all of them are consumer apps, the decomposition did not take. Go back to the mechanic statement and strip whatever domain noun is still hiding in it.

## Where to look

- **Who has the hardest version of this problem?** Extremity forces good solutions. Duolingo's retention problem is harder than a fitness app's — language learning has no physical feedback loop and no visible result for months — so their machinery is more developed.
- **Who monetises on solving it?** Where the mechanic is the revenue model rather than a feature, the implementation is best-in-class and usually documented.
- **Games.** Most engagement mechanics originate there, and game design has decades of practice on progression, pacing, and reward schedules that product work rediscovers badly.
- **Same structural shape, any vertical** — two-sided marketplace, habit formation, cold start, trust between strangers, high-consideration purchase, expert-to-novice translation.
- **Who solved it under constraints like ours?** A small team with no infrastructure that shipped this is often a better source than the market leader with a data science org, because their solution is one we can actually copy.
- **Where has it been formally studied?** The mechanic usually has a literature (tier 3), and that literature is domain-general by construction.

## Best-in-class, not best-known

The famous example is not automatically the strongest implementation — it is the most written-about, which is a different property. Biggest is not best either. Check whether the obvious name actually does this well, or is simply the one everyone cites when the topic comes up.

## Structural-similarity test

**The further the analogy, the more load the transfer analysis carries.** Score the source against our context; each mismatch is a specific thing the write-up must address.

| Dimension | Ask |
|---|---|
| Frequency | How often does the behaviour happen for them vs for us? |
| Effort per interaction | Minutes, or an hour? Micro-interactions, or one commitment? |
| **Is abstention bad?** | Skipping is failure for them — is it for us? Sometimes not doing it is *correct*. |
| Verifiability | Can the system tell a real action from a claimed one? |
| Cost of failure to the user | Trivial, or expensive, or physically risky? |
| Who pays, and for what | Does the mechanic serve the payer or the free user? |
| Cold start / network effects | Does it need other people present to work at all? |

A mismatch does not disqualify an analogue — it locates the work. Borrowing a daily language-learning streak into a training app mismatches on four dimensions at once: frequency (daily versus a few sessions a week), session length (minutes versus most of an hour), abstention (rest days are *good*, so a broken streak is not failure), and verifiability (a self-typed entry is unfalsifiable, a completed lesson is not). Each mismatch inverts part of the mechanic, and the daily streak has to become a weekly one to survive the move. Verify the frequency figures for your own case rather than carrying an assumed number into the pacing math — the gap between assumed and actual cadence is a common source of a design built for a user who does not exist.

## Do not lift a mechanic out of its supporting cast

A mechanic that works usually depends on two or three others around it. Streaks work partly because sessions are short enough to complete on a bad day, because freezes exist, and because repair is forgiving. Copy the streak alone and the anxiety arrives without the mitigation.

Before copying, list what props it up, and decide about each explicitly — including the ones we are choosing not to build.

## Report it as an analogue

Name the source domain and the mismatches in the write-up. A reader who does not know a mechanic came from language learning cannot judge whether the transfer holds, and will assume it was validated in our category.
