---
applyTo: '**/app/**/*.rb,**/spec/**/*.rb,**/test/**/*.rb,**/db/**/*.rb,**/config/**/*.rb'
paths:
  - '**/app/**/*.rb'
  - '**/spec/**/*.rb'
  - '**/test/**/*.rb'
  - '**/db/**/*.rb'
  - '**/config/**/*.rb'
detect:
  - '**/config/routes.rb'
  - '**/Gemfile'
---

# Rails Rules

## Business Invariants
- A service object exposes one public method, `#call`. Everything else is private. A second public method means a second service.
- A service returns a result value carrying success, data, and error — `Data.define(:success, :data, :error)`. It does not raise for a business failure; a raise is reserved for a broken invariant the caller cannot handle.
- Work that writes more than one model wraps in a transaction. A partial write is the defect this prevents, and it does not announce itself.
- A controller action reads params, calls one service, and renders. Business logic in a controller is untestable without the request cycle.
- A model holds validations, associations, and scopes. Multi-model orchestration belongs in a service, not in a callback — a callback fires on every save path, including the ones you did not intend.
- Every query that renders an association loads it with `includes`. An N+1 passes every test that uses one record.
- A schema change ships as a migration. Never edit `db/schema.rb` by hand; it is generated output.

## Abnormal Cases and Rationale
- Strong parameters filter mass assignment, not authorization. A permitted attribute is still an attribute the caller chose — check who may set it.
- A single-table-inheritance table whose subtype-specific columns pass a fifth of the total holds two tables. Split it.
- A concern past thirty lines is a module with no owner. Name the responsibility and give it a class.

## Out of Scope
- Do not restate background-job or cache configuration here. The application's own `config/` owns those, and the adapter varies per deployment.
