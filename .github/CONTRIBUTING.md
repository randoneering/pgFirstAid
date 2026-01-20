# Contributing to pgFirstAid

Thank you for your interest in contributing to pgFirstAid! This project is community-driven, and contributions of all kinds are welcome.

## Code of Conduct

This project follows the [Contributor Covenant](https://www.contributor-covenant.org/version/3/0/code_of_conduct/). By participating, you agree to uphold a welcoming and inclusive environment.

## Ways to Contribute

- **New health checks** - Propose or implement checks for database issues not yet covered. Use `feature/` for new health checks
- **Bug fixes** - Found something broken? PRs welcome. Use `bug/` for bug fix branches
- **Documentation** - Improve README, add examples, clarify explanations. Use `docs/` for any documentation releated contributions
- **Testing** - Validate checks across PostgreSQL versions and cloud providers
- **Feature requests** - Open an issue describing your idea

## Development Setup

The `testing/` directory contains OpenTofu modules for provisioning PostgreSQL instances on major cloud providers (AWS RDS, Aurora, GCP Cloud SQL, Azure). Use these to validate your changes against real managed database environments.

```bash
cd testing/<provider>
tofu init
tofu apply
```

## Testing Requirements

Before submitting a PR, test your changes against:

**PostgreSQL Versions:**
- [ ] PostgreSQL 15
- [ ] PostgreSQL 16
- [ ] PostgreSQL 17
- [ ] PostgreSQL 18

**Cloud Providers (if applicable):**
- [ ] AWS RDS
- [ ] AWS Aurora
- [ ] GCP Cloud SQL
- [ ] Azure Database for PostgreSQL

Not everyone has access to all environments. Document what you tested in your PR, and maintainers or other contributors can help validate the rest.

## Submitting a Pull Request

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/new-health-check`)
3. Make your changes
4. Test against available PostgreSQL versions
5. Submit a PR using the provided template

### PR Review Process

- At least 1 maintainer must approve before merging
- Be patient—this is a side project maintained in spare time
- Expect acknowledgment within a reasonable timeframe, with detailed review to follow

## SQL Style Guidelines

Follow the existing code style in the repository:

- Lowercase SQL keywords (`select`, `from`, `where`, `insert`)
- Lowercase for column names, table names, and aliases
- Use meaningful aliases for subqueries and CTEs
- Include comments explaining complex logic
- Match the existing health check structure (severity, category, check_name, etc.)

## Health Check Structure

Each health check should return rows matching this structure:

| Column | Description |
|--------|-------------|
| `severity` | CRITICAL, HIGH, MEDIUM, LOW, or INFO |
| `category` | Grouping (e.g., Table Structure, Index Management) |
| `check_name` | Short descriptive name |
| `object_name` | schema.object being flagged |
| `issue_description` | What the problem is |
| `current_value` | Current state/metrics |
| `recommended_action` | What to do about it |
| `documentation_link` | Link to PostgreSQL docs |

## Questions?

Open an issue or reach out through the channels listed in the README (if applicable.)

---

Thank you for helping make PostgreSQL health monitoring accessible to everyone!
