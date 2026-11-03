-- Fixed demo rows that the fixture product pages, tests and the admin UI rely
-- on, plus demo auth users. Called from seed.sql (local/CI) and once on the
-- hosted demo project.

create or replace function synthetic.setup_fixtures()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_brand bigint;
  v_source bigint;
  v_product bigint;
  v_res jsonb;
begin
  -- Sources the fixture pages come from, with known trust levels.
  insert into public.sources (domain, name, kind, trust_level, rate_limit_per_min) values
    ('velvane-skin.example', 'Velvane Skin (brand site)', 'brand_site', 'trusted', 30),
    ('northfern.example', 'Northfern (brand site)', 'brand_site', 'trusted', 30),
    ('ondessa-hair.example', 'Ondessa Hair (brand site)', 'brand_site', 'trusted', 30),
    ('saltglass.example', 'Saltglass (brand site)', 'brand_site', 'trusted', 30),
    ('halcyra.example', 'Halcyra (brand site)', 'brand_site', 'trusted', 30),
    ('petalwright.example', 'Petalwright (brand site)', 'brand_site', 'trusted', 2),
    ('dermadeals.example', 'DermaDeals (marketplace)', 'retailer', 'suspect', 10)
  on conflict (domain) do update set trust_level = excluded.trust_level, rate_limit_per_min = excluded.rate_limit_per_min;

  -- Saltglass sunscreen already has a human-verified list. The fixture page
  -- scraped later differs, so the pipeline must draft rather than overwrite.
  select id into v_brand from public.brands where name = 'Saltglass';
  select id into v_source from public.sources where domain = 'saltglass.example';
  insert into public.products (brand_id, name, category, product_type, product_url, source_id, status, published_at)
  values (v_brand, 'Mineral Sunscreen SPF 30', 'suncare', 'sunscreen_mineral',
          'https://saltglass.example/products/mineral-sunscreen-spf-30', v_source, 'published', now() - interval '90 days')
  on conflict (product_url) do nothing
  returning id into v_product;

  if v_product is not null then
    v_res := public.repair_product_ingredients(v_product,
      '["Aqua", "Zinc Oxide", "Caprylic/Capric Triglyceride", "Coco-Caprylate/Caprate", "Glycerin",
        "Cetearyl Alcohol", "Polyglyceryl-3 Methylglucose Distearate", "Xanthan Gum", "Tocopherol",
        "Phenoxyethanol", "Ethylhexylglycerin"]'::jsonb,
      'verified', null, 'fixture: verified against physical label');
    perform public.cache_put(v_product, 'ingredient_score', 'internal', 'scorer-4', 'v4', v_res ->> 'hash',
                             '{"score": 88, "allergens": 0}'::jsonb);
    perform public.cache_put(v_product, 'safety_narrative', 'anthropic', 'claude-sonnet-5-5', 'v3', v_res ->> 'hash',
                             '{"summary": "Fragrance-free mineral SPF built on zinc oxide; no declarable allergens."}'::jsonb);
  end if;

  return jsonb_build_object('saltglass_product', v_product);
end;
$$;

create or replace function synthetic.ensure_demo_user(p_email text, p_password text, p_admin boolean)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from auth.users where email = lower(p_email);
  if v_id is not null then
    update auth.users
       set raw_app_meta_data = jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email'))
                               || case when p_admin then '{"role": "admin"}'::jsonb else '{}'::jsonb end,
           encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf'))
     where id = v_id;
    return v_id;
  end if;
  v_id := gen_random_uuid();
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', lower(p_email),
          extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
          jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email'))
            || case when p_admin then '{"role": "admin"}'::jsonb else '{}'::jsonb end,
          '{}'::jsonb, now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_id, v_id::text,
          jsonb_build_object('sub', v_id::text, 'email', lower(p_email), 'email_verified', true),
          'email', now(), now(), now());
  return v_id;
end;
$$;
