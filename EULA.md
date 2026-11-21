# Kubexa Software License Agreement

**Version 1.0 — effective 2026-11-19**

> **Not reviewed by counsel.** This text has not been reviewed by a lawyer.
> It also states no registered address, because as of the effective date the
> licensor is a natural person and has none; notices are given by email under
> section 14. Both are expected to change in a later version, and section 8
> limits any such version to releases published after it.

This agreement governs your use of the Kubexa server software. Read it before
you install. By installing, running, or otherwise using the Software you accept
these terms; if you do not accept them, do not install the Software.

Licensor: **Eyüp Saral**, trading as Kubexa, resident in the Republic of
Türkiye ("we", "us"). You: the individual or legal entity installing or running
the Software ("you").

---

## 1. What this agreement covers

"Software" means the following container images published at `ghcr.io/kubexa`,
including every version and tag of each, together with their accompanying
documentation:

| Image | Component |
| --- | --- |
| `ghcr.io/kubexa/kubexa-backend` | API server and agent gateway |
| `ghcr.io/kubexa/kubexa-app` | Web console |
| `ghcr.io/kubexa/kubexa-consumer` | Telemetry consumer |
| `ghcr.io/kubexa/kubexa-backup` | Backup and restore utility |

## 2. What this agreement does NOT cover

This agreement grants no rights in, and places no restrictions on, any of the
following. Each is governed by its own license, and where that license
conflicts with this agreement, that license prevails for that component.

* **The Kubexa agent** — source at `github.com/kubexa/kubexa-agent`, image
  `ghcr.io/kubexa/kubexa-agent`, chart `kubexa/kubexa-agent`. Licensed under the
  **GNU General Public License v3.0**.
* **The Helm charts** in the `kubexa/helm-charts` repository. Licensed under the
  **Apache License 2.0**; see that repository's `LICENSE` for its exact scope.
* **Third-party software the charts deploy** — including PostgreSQL, Valkey,
  NATS, VictoriaMetrics and Grafana Loki. Each is distributed by its own vendor
  under its own license. Some of these are copyleft licenses with obligations of
  their own. We do not sublicense them to you, and you are responsible for
  reviewing their terms for your own deployment.
* **Third-party libraries compiled into the Software.** Every image carries
  `/THIRD-PARTY-NOTICES.md`, generated when the image is built from the
  libraries actually linked into it and reproducing each one's licence in full.
  Those licences remain in force. The server images carry no shell, so read it
  from the image with `docker create` and `docker cp` rather than from a
  running container.

## 3. What you may do

We grant you a non-exclusive, non-transferable, non-sublicensable right, for the
term of this agreement, to:

1. install and run any number of instances of the Software on infrastructure you
   control, for your own internal business purposes;
2. use the Software to monitor and operate Kubernetes clusters that you or your
   group of companies own or operate;
3. make copies of the Software as reasonably required for installation, backup
   and disaster recovery;
4. modify the Software's configuration, and deploy it with modified Helm values.

No fee is charged for the rights in this section as of the effective date above.
That is a present fact, not a perpetual commitment: see section 8.

## 4. What you may not do

You may not:

1. **redistribute, sell, rent, lease, lend or sublicense** the Software, or make
   it available to any third party, whether or not for a fee;
2. **provide the Software, or its functionality, to third parties as a hosted,
   managed or multi-tenant service** — including any offering in which a party
   other than you or your group of companies is the beneficiary of the
   Software's operation;
3. **use the Software to build, train or operate a product that competes with
   it**, or incorporate any part of it into such a product;
4. remove, obscure or alter any copyright, trademark, licensing or attribution
   notice in the Software, its console, its logs or its documentation;
5. use the Kubexa name, logo or other marks except to state factually that you
   run the Software;
6. reverse engineer, decompile or disassemble the Software, or attempt to derive
   its source code — **except** to the extent that mandatory applicable law
   grants you that right and that right cannot lawfully be waived. Where such a
   right applies (for example, an interoperability right under Turkish law or
   Article 6 of Directive 2009/24/EC), nothing in this agreement restricts it,
   and we ask that you contact us first in case we can simply supply the
   information you need.

Clause 2 is the one that matters most to us, so to be unambiguous: running
Kubexa to operate your own clusters is exactly what it is for. Running Kubexa so
that other organisations can operate theirs is not, and needs a separate written
agreement with us.

## 5. Ownership

The Software is licensed, not sold. We and our licensors retain all right, title
and interest in it, including all intellectual property rights. You acquire no
rights beyond those stated in section 3.

## 6. Your data

The Software runs on your infrastructure and stores its data there. We have no
access to it and receive no telemetry from your installation. We are not a
processor of any personal data the Software holds, and we provide no undertaking
about it; it is yours to govern. The Kubexa agent's own behaviour in your
clusters is documented in `docs/agent/what-the-agent-collects`.

## 7. Support and updates

This agreement entitles you to neither. We publish releases at our discretion
and may stop. Technical support, response commitments, and any obligation to fix
a defect exist only under a separate written agreement.

## 8. Changes to these terms

We may publish a new version of this agreement. A new version applies to
versions of the Software released after it; it does not retroactively change the
terms under which you received a version you already run. If you do not accept a
new version, stop upgrading — your existing installation stays under the terms
you accepted.

## 9. Term and termination

This agreement starts when you first install the Software and continues until
terminated.

* You may terminate at any time by ceasing all use and destroying your copies.
* We may terminate it if you breach section 4 and do not remedy the breach
  within 30 days of written notice to you.

On termination you must stop using the Software and destroy all copies. Sections
5, 10, 11 and 12 survive termination.

## 10. No warranty

THE SOFTWARE IS PROVIDED "AS IS" AND "AS AVAILABLE", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, ACCURACY, AND
NON-INFRINGEMENT. WE DO NOT WARRANT THAT THE SOFTWARE WILL BE UNINTERRUPTED,
ERROR-FREE, OR THAT IT WILL DETECT, REPORT OR PREVENT ANY PARTICULAR CONDITION
IN YOUR CLUSTERS.

Kubexa observes and operates production infrastructure. Do not rely on it as the
only safeguard against an outage, a data loss, or a security incident.

## 11. Limitation of liability

TO THE MAXIMUM EXTENT PERMITTED BY APPLICABLE LAW, WE WILL NOT BE LIABLE FOR ANY
INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL OR PUNITIVE DAMAGES, NOR FOR ANY
LOSS OF PROFITS, REVENUE, DATA, GOODWILL, OR ANTICIPATED SAVINGS, ARISING OUT OF
OR RELATING TO THE SOFTWARE OR THIS AGREEMENT, WHETHER IN CONTRACT, TORT OR
OTHERWISE, EVEN IF ADVISED OF THE POSSIBILITY.

Because the Software is supplied to you free of charge, our total aggregate
liability arising out of or relating to the Software and this agreement is
limited to one hundred (100) Turkish Lira.

Nothing in this agreement excludes or limits liability that cannot lawfully be
excluded or limited, including liability for death or personal injury caused by
negligence, for fraud, or for fraudulent misrepresentation.

## 12. Governing law and venue

This agreement is governed by the laws of the Republic of Türkiye, without
regard to its conflict-of-laws rules. It makes no venue agreement of its own:
jurisdiction lies with whatever courts Turkish procedural law designates as
competent. Either party may seek injunctive relief in any competent court to
protect its intellectual property.

If you are a consumer rather than a business, mandatory consumer-protection law
in your country of residence applies to you regardless of this section.

## 13. General

* **Entire agreement.** This is the whole agreement about the Software and
  replaces any earlier understanding about it.
* **Severability.** If a provision is unenforceable, the rest stays in force and
  the unenforceable provision is read down to the minimum extent needed.
* **No waiver.** A right we do not enforce immediately is not waived.
* **Assignment.** You may not assign this agreement without our written
  consent. We may assign it in connection with a merger, acquisition or sale of
  assets.
* **Export and sanctions.** You must not use or re-export the Software in breach
  of applicable export-control or sanctions law.

## 14. Notices and contact

Send notices under this agreement, and any licensing question, to
**legal@kubexa.dev**. A licence covering use that section 4 does not permit —
including offering Kubexa as a service — is available by agreement; ask.
