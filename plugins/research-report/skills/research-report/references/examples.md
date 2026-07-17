# Worked fixes

Before/after pairs from a real rewrite (a model note the loop caught defects in twice). Each shows one contract rule or gate finding in action.

## Rule 1 — no code references

The reader cannot open the repository and must never be sent there.

- **Before:** the covariance is evaluated in `src/autocast/losses/gaussian.py` via the Woodbury identity.
- **After:** the covariance is evaluated using the Woodbury identity — the rule that rewrites the inverse of a diagonal-plus-low-rank matrix using only a small $r\times r$ inverse — so the cost stays linear in $N$ and the full $N\times N$ matrix is never formed.

The guard greps for source extensions and path prefixes and hard-fails on the "before" line.

## Rule 2 — plain words, no coined or fancy terms

- **Before:** the *amortised* prediction head; the modes are algebraically *slaved* to the mean.
- **After:** the prediction head, which shares one set of weights across all inputs; the modes are forced to track the mean — they cannot vary independently of it.

`amortis`, `slave`, `pricing`, `surrogate` are in the guard denylist. When the cold reader flags a new offender, add its stem there too.

## Rule 4 — derive load-bearing math, don't assert it

The single most common cold-read failure: a result the whole argument rests on, stated as a one-liner.

- **Before:** the precision update is $\mathbb{E}[\alpha_k] = (N+2a_0)/(S_k+2b_0)$.
- **After (appendix):** collect every term of the bound that involves $\alpha_k$ — the loadings' log-prior averaged over their distribution, $\tfrac{N}{2}\log\alpha_k - \tfrac{\alpha_k}{2}S_k$, plus the Gamma log-prior — recognise the sum as a log-Gamma density, read off $\mathrm{Gamma}(a_k,b_k)$ with $a_k=a_0+\tfrac N2$, $b_k=b_0+\tfrac12 S_k$, and take its mean $a_k/b_k$. *Then* note that the single-best-value version takes the **mode** $(a_k-1)/b_k$ of the same Gamma — the one-shape-shift that is the entire source of a stray $-1$ elsewhere.

The cold reader flagged the "before" as "asserted, and never reconciled with the other formula." Deriving it once removed both complaints.

## Rule 3 — name the object before you use it

A metric carrying load-bearing numbers must be named and defined at first use.

- **Before:** a divergence to the true covariance of $0.0036$ … (and "divergence" recurs with numbers for pages, named only once, much later, in a table).
- **After:** closeness is measured throughout by the Kullback–Leibler divergence between the fitted and the true covariance, each read as a zero-mean Gaussian — zero means they match exactly — here $0.0036$.

## Gate finding — ambiguous notation is a real defect

Two independent cold readers both read the superscript on $\Sigma^U_{ik}$ (a per-entry variance) as "$\Sigma^{ll}$". Inspection of the typeset PDF confirmed the non-bold italic superscript renders as two thin strokes in this font at superscript size.

- **Before:** $q(U_{ik}) = \mathcal{N}(M_{ik},\ \Sigma^U_{ik})$ — mean $M$, variance $\Sigma^U$.
- **After:** $q(U_{ik}) = \mathcal{N}(M_{ik},\ V_{ik})$ — variance $V$, parallel to the mean $M$, with no confusable superscript.

Lesson: when a fresh reader misreads a glyph, do not dismiss it as their error — look at the rendered PDF, and if the glyph is genuinely ambiguous, change the notation.
