-- One-off seed for the hosted demo project (synthetic data only).
select synthetic.generate_catalog(5000, 42);
select synthetic.setup_fixtures();
select synthetic.ensure_demo_user('admin@catalog-demo.example', 'catalog-demo-2026', true);
select private.run_hygiene_job('url_trust');
select private.run_hygiene_job('stale_cache');
select private.run_hygiene_job('quality_report');
-- keep a little work in the queue for visitors
select cron.schedule('demo-top-up', '0 3 * * *', $$select synthetic.top_up_demo(40)$$);
