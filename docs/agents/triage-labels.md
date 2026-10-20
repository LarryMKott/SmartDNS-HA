# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

Edit the right-hand column to match whatever vocabulary you actually use.

## Category roles

Every triaged issue also carries exactly one **category** role. These use GitHub's stock label strings, so no new labels were created:

| Role in mattpocock/skills | Label in our tracker | Meaning                 |
| ------------------------- | -------------------- | ----------------------- |
| `bug`                     | `bug`                | Something is broken     |
| `enhancement`             | `enhancement`        | New feature or request  |

## Wayfinder labels

`/wayfinder` charts a map as one issue plus child decision tickets. These labels were created so the skill can find them:

| Label              | Meaning                                          |
| ------------------ | ------------------------------------------------ |
| `wayfinder:map`    | The map itself: the canonical issue for one effort |
| `wayfinder:research`  | Ticket resolved by reading external sources   |
| `wayfinder:prototype` | Ticket resolved by building a rough artifact  |
| `wayfinder:grilling`  | Ticket resolved by a live exchange with a human |
| `wayfinder:task`      | Manual work that must happen before a decision |

No label beyond these is required. Don't invent extra tracking labels per issue.
