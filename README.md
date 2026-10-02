# RetailFlow

RetailFlow is a multi-tenant retail sales, point-of-sale, and inventory management platform developed by PAOTechs.

## Development workflow

RetailFlow follows the same release workflow used by LabaFlow:

- GitHub is the source of truth.
- Supabase provides Postgres, Authentication, Storage, Row-Level Security, and RPC functions.
- Vercel provides staging and production deployments.
- Feature work is developed and verified in staging.
- Production deployment happens only after approval.
- Database migrations are committed to Git and applied in numeric order.
- Secrets are stored only in local or Vercel environment variables.

## Technology

- React 19 and TypeScript
- Vinext/Vite
- Supabase
- Vercel

## Environment strategy

| Environment | Git branch | Supabase | Vercel |
|---|---|---|---|
| Staging | `staging` | Dedicated staging project | Staging deployment |
| Production | `main` | Dedicated production project | Production deployment |

Production Supabase project:

- Project URL: `https://fuplobbciabkikfzrxdt.supabase.co`
- Project name: RetailFlow

Do not commit database passwords, service-role keys, publishable keys, access tokens, or other secrets.

## Architecture principles

- Multi-tenant isolation begins in migration `001`.
- Organizations contain branches and operational users.
- Platform administrators are platform-level accounts and do not require organization membership.
- Every tenant-owned record carries an `organization_id`.
- Branch-owned operational records also carry a `branch_id`.
- Row-Level Security enforces isolation in the database, not only in the interface.
- Organization features and limits are configuration-driven.
- Organization-specific workflows are optional paid extensions and must not fork the core product.

## Initial delivery phases

1. Application scaffold and environment configuration
2. Multi-tenant database foundation
3. Authentication and organization onboarding
4. Platform and organization administration
5. Products, categories, barcodes, and branch pricing
6. Inventory and stock movements
7. Point of sale, payments, and receipts
8. Purchasing, expenses, stocktake, and transfers
9. Reports, audit, backup, and recovery controls
10. Mobile printing and optional mobile applications

## Local setup

1. Copy `.env.example` to `.env.local`.
2. Add the Supabase URL and publishable key for the intended environment.
3. Install dependencies with `npm install`.
4. Apply migrations from `supabase/migrations` in numeric order.
5. Start the application with `npm run dev`.

## Status

RetailFlow is being rebuilt from a clean foundation using the proven LabaFlow development and deployment model.
