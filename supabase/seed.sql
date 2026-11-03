-- Local/CI seed: a small synthetic catalog plus the fixed rows the fixture
-- pages and tests rely on. The 50k benchmark uses scripts/seed-scale.sh.
-- All brands, products and people here are fictional.

select synthetic.generate_catalog(300, 42);
select synthetic.setup_fixtures();

-- Demo logins (synthetic data only; the admin password is shown on the demo login page).
select synthetic.ensure_demo_user('admin@catalog-demo.example', 'catalog-demo-2026', true);
select synthetic.ensure_demo_user('viewer@catalog-demo.example', 'catalog-demo-2026', false);

select private.run_hygiene_job('quality_report');
