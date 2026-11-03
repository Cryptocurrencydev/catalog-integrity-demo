-- Synthetic beauty / personal-care catalog generator (fictional brands only).
-- synthetic.generate_catalog(n) builds n products with realistic INCI lists in
-- label order, a provenance mix, AI cache history, queue/draft backlog and
-- audit history. Deterministic for a given seed. Used by seed.sql (small),
-- scripts/seed-scale.sh (50k) and the hosted demo (5k).

create schema if not exists synthetic;
revoke all on schema synthetic from public;

-- ---------------------------------------------------------------------------
-- Curated INCI dictionary: (inci, function, allergen, common name, aliases)
-- Within a function, earlier rows are more popular in generated formulas.
-- ---------------------------------------------------------------------------
create table synthetic.curated_inci (
  ord int generated always as identity,
  inci text primary key,
  fn text not null,
  allergen boolean not null default false,
  common_name text,
  aliases text[] not null default '{}'
);

insert into synthetic.curated_inci (inci, fn, allergen, common_name, aliases) values
-- solvent
('Aqua', 'solvent', false, 'Water', '{Water,Eau,Aqua/Water,Aqua/Water/Eau,Water/Aqua/Eau,Purified Water,Deionized Water,Demineralized Water}'),
-- humectants
('Glycerin', 'humectant', false, null, '{Glycerine,Glycerol,Vegetable Glycerin}'),
('Butylene Glycol', 'humectant', false, null, '{}'),
('Propanediol', 'humectant', false, null, '{1,3-Propanediol}'),
('Sodium Hyaluronate', 'humectant', false, null, '{Hyaluronic Acid Sodium Salt}'),
('Panthenol', 'humectant', false, 'Pro-Vitamin B5', '{D-Panthenol,Provitamin B5,Pro-Vitamin B5,Vitamin B5,Dexpanthenol}'),
('Propylene Glycol', 'humectant', false, null, '{}'),
('Sodium PCA', 'humectant', false, null, '{}'),
('Betaine', 'humectant', false, null, '{}'),
('Pentylene Glycol', 'humectant', false, null, '{}'),
('Hyaluronic Acid', 'humectant', false, null, '{}'),
('Sorbitol', 'humectant', false, null, '{}'),
('Urea', 'humectant', false, null, '{}'),
('Glyceryl Glucoside', 'humectant', false, null, '{}'),
('Trehalose', 'humectant', false, null, '{}'),
('Sodium Lactate', 'humectant', false, null, '{}'),
('Hydroxyethyl Urea', 'humectant', false, null, '{}'),
('Sodium Polyglutamate', 'humectant', false, null, '{Polyglutamic Acid}'),
('Hydrolyzed Hyaluronic Acid', 'humectant', false, null, '{Hydrolysed Hyaluronic Acid}'),
('Dipropylene Glycol', 'humectant', false, null, '{}'),
('Methyl Gluceth-20', 'humectant', false, null, '{}'),
('Inositol', 'humectant', false, null, '{}'),
('Xylitol', 'humectant', false, null, '{}'),
-- emollients
('Caprylic/Capric Triglyceride', 'emollient', false, null, '{Caprylic Capric Triglyceride,Caprylic Capric Triglycerides,Caprylic/Capric Triglycerides,MCT Oil,Fractionated Coconut Oil}'),
('Squalane', 'emollient', false, null, '{Olive Squalane}'),
('Dimethicone', 'emollient', false, null, '{}'),
('Isopropyl Myristate', 'emollient', false, null, '{}'),
('Ethylhexyl Palmitate', 'emollient', false, null, '{}'),
('Butyrospermum Parkii Butter', 'emollient', false, 'Shea Butter', '{Shea Butter,Butyrospermum Parkii (Shea) Butter,Organic Shea Butter}'),
('Simmondsia Chinensis Seed Oil', 'emollient', false, 'Jojoba Oil', '{Jojoba Oil,Simmondsia Chinensis (Jojoba) Seed Oil}'),
('Helianthus Annuus Seed Oil', 'emollient', false, 'Sunflower Oil', '{Sunflower Seed Oil,Sunflower Oil}'),
('Prunus Amygdalus Dulcis Oil', 'emollient', false, 'Sweet Almond Oil', '{Sweet Almond Oil}'),
('Coco-Caprylate/Caprate', 'emollient', false, null, '{}'),
('Isononyl Isononanoate', 'emollient', false, null, '{}'),
('C12-15 Alkyl Benzoate', 'emollient', false, null, '{}'),
('Dicaprylyl Carbonate', 'emollient', false, null, '{}'),
('Argania Spinosa Kernel Oil', 'emollient', false, 'Argan Oil', '{Argan Oil,Argania Spinosa (Argan) Kernel Oil}'),
('Olea Europaea Fruit Oil', 'emollient', false, 'Olive Oil', '{Olive Oil,Olea Europaea (Olive) Fruit Oil}'),
('Persea Gratissima Oil', 'emollient', false, 'Avocado Oil', '{Avocado Oil}'),
('Hydrogenated Polydecene', 'emollient', false, null, '{}'),
('Paraffinum Liquidum', 'emollient', false, 'Mineral Oil', '{Mineral Oil,Liquid Paraffin}'),
('Petrolatum', 'emollient', false, null, '{Petroleum Jelly}'),
('Cyclopentasiloxane', 'emollient', false, null, '{}'),
('Dimethiconol', 'emollient', false, null, '{}'),
('Cocos Nucifera Oil', 'emollient', false, 'Coconut Oil', '{Coconut Oil}'),
('Ricinus Communis Seed Oil', 'emollient', false, 'Castor Oil', '{Castor Oil}'),
('Theobroma Cacao Seed Butter', 'emollient', false, 'Cocoa Butter', '{Cocoa Butter}'),
('Macadamia Ternifolia Seed Oil', 'emollient', false, 'Macadamia Oil', '{Macadamia Oil}'),
('Limnanthes Alba Seed Oil', 'emollient', false, 'Meadowfoam Seed Oil', '{Meadowfoam Seed Oil}'),
('Cera Alba', 'emollient', false, 'Beeswax', '{Beeswax}'),
('Copernicia Cerifera Cera', 'emollient', false, 'Carnauba Wax', '{Carnauba Wax}'),
('Phenyl Trimethicone', 'emollient', false, null, '{}'),
('Caprylyl Methicone', 'emollient', false, null, '{}'),
('Isohexadecane', 'emollient', false, null, '{}'),
('Isododecane', 'emollient', false, null, '{}'),
-- emulsifiers / fatty alcohols
('Cetearyl Alcohol', 'emulsifier', false, null, '{Cetostearyl Alcohol,Cetyl Stearyl Alcohol}'),
('Glyceryl Stearate', 'emulsifier', false, null, '{}'),
('Cetyl Alcohol', 'emulsifier', false, null, '{}'),
('PEG-100 Stearate', 'emulsifier', false, null, '{}'),
('Ceteareth-20', 'emulsifier', false, null, '{}'),
('Stearyl Alcohol', 'emulsifier', false, null, '{}'),
('Cetearyl Glucoside', 'emulsifier', false, null, '{}'),
('Polysorbate 20', 'emulsifier', false, null, '{}'),
('Polysorbate 60', 'emulsifier', false, null, '{}'),
('Sorbitan Olivate', 'emulsifier', false, null, '{}'),
('Cetearyl Olivate', 'emulsifier', false, null, '{}'),
('Glyceryl Stearate Citrate', 'emulsifier', false, null, '{}'),
('Potassium Cetyl Phosphate', 'emulsifier', false, null, '{}'),
('Steareth-2', 'emulsifier', false, null, '{}'),
('Steareth-21', 'emulsifier', false, null, '{}'),
('Lecithin', 'emulsifier', false, null, '{}'),
('Sorbitan Stearate', 'emulsifier', false, null, '{}'),
('Polyglyceryl-3 Methylglucose Distearate', 'emulsifier', false, null, '{}'),
('Behenyl Alcohol', 'emulsifier', false, null, '{}'),
('Arachidyl Glucoside', 'emulsifier', false, null, '{}'),
('Sucrose Stearate', 'emulsifier', false, null, '{}'),
-- surfactants
('Sodium Laureth Sulfate', 'surfactant', false, null, '{SLES}'),
('Cocamidopropyl Betaine', 'surfactant', false, null, '{CAPB}'),
('Sodium Lauryl Sulfate', 'surfactant', false, null, '{SLS}'),
('Sodium Cocoyl Isethionate', 'surfactant', false, null, '{}'),
('Decyl Glucoside', 'surfactant', false, null, '{}'),
('Coco-Glucoside', 'surfactant', false, null, '{}'),
('Lauryl Glucoside', 'surfactant', false, null, '{}'),
('Sodium Lauroyl Sarcosinate', 'surfactant', false, null, '{}'),
('Disodium Cocoamphodiacetate', 'surfactant', false, null, '{}'),
('Sodium Methyl Cocoyl Taurate', 'surfactant', false, null, '{}'),
('Sodium Cocoyl Glutamate', 'surfactant', false, null, '{}'),
('Sodium C14-16 Olefin Sulfonate', 'surfactant', false, null, '{}'),
('Cocamide MEA', 'surfactant', false, null, '{}'),
('Lauryl Betaine', 'surfactant', false, null, '{}'),
('Sodium Cocoamphoacetate', 'surfactant', false, null, '{}'),
('Disodium Laureth Sulfosuccinate', 'surfactant', false, null, '{}'),
('Sodium Lauroyl Methyl Isethionate', 'surfactant', false, null, '{}'),
('Glycol Distearate', 'surfactant', false, null, '{}'),
-- hair conditioning
('Behentrimonium Chloride', 'conditioning', false, null, '{}'),
('Cetrimonium Chloride', 'conditioning', false, null, '{}'),
('Polyquaternium-10', 'conditioning', false, null, '{}'),
('Guar Hydroxypropyltrimonium Chloride', 'conditioning', false, null, '{}'),
('Amodimethicone', 'conditioning', false, null, '{}'),
('Hydrolyzed Keratin', 'conditioning', false, null, '{Hydrolysed Keratin,Keratin}'),
('Hydrolyzed Wheat Protein', 'conditioning', false, null, '{Hydrolysed Wheat Protein,Wheat Protein}'),
('Stearamidopropyl Dimethylamine', 'conditioning', false, null, '{}'),
('Behentrimonium Methosulfate', 'conditioning', false, null, '{}'),
('Polyquaternium-7', 'conditioning', false, null, '{}'),
('Trideceth-12', 'conditioning', false, null, '{}'),
-- actives
('Niacinamide', 'active', false, 'Vitamin B3', '{Nicotinamide,Vitamin B3,Niacin Amide}'),
('Allantoin', 'active', false, null, '{}'),
('Tocopherol', 'antioxidant', false, 'Vitamin E', '{Vitamin E,D-Alpha Tocopherol,Mixed Tocopherols,Vit E,Vit. E}'),
('Ascorbic Acid', 'active', false, 'Vitamin C', '{Vitamin C,L-Ascorbic Acid}'),
('Salicylic Acid', 'active', false, 'BHA', '{BHA,Beta Hydroxy Acid}'),
('Ceramide NP', 'active', false, null, '{Ceramide 3}'),
('Bisabolol', 'active', false, null, '{Alpha-Bisabolol}'),
('Sodium Ascorbyl Phosphate', 'active', false, null, '{}'),
('Retinol', 'active', false, 'Vitamin A', '{Vitamin A}'),
('Glycolic Acid', 'active', false, 'AHA', '{AHA,Alpha Hydroxy Acid}'),
('Lactic Acid', 'active', false, null, '{}'),
('Ceramide AP', 'active', false, null, '{Ceramide 6 II}'),
('Ceramide EOP', 'active', false, null, '{Ceramide 1}'),
('Phytosphingosine', 'active', false, null, '{}'),
('Cholesterol', 'active', false, null, '{}'),
('Adenosine', 'active', false, null, '{}'),
('Zinc PCA', 'active', false, null, '{}'),
('Tranexamic Acid', 'active', false, null, '{}'),
('Alpha-Arbutin', 'active', false, null, '{}'),
('Caffeine', 'active', false, null, '{}'),
('Madecassoside', 'active', false, null, '{}'),
('Bakuchiol', 'active', false, null, '{}'),
('Gluconolactone', 'active', false, 'PHA', '{PHA}'),
('Ectoin', 'active', false, null, '{}'),
('Biotin', 'active', false, null, '{Vitamin B7}'),
('Piroctone Olamine', 'active', false, null, '{}'),
('Zinc Pyrithione', 'active', false, null, '{}'),
('Mandelic Acid', 'active', false, null, '{}'),
('Azelaic Acid', 'active', false, null, '{}'),
('Retinyl Palmitate', 'active', false, null, '{}'),
('Hydroxypinacolone Retinoate', 'active', false, null, '{}'),
('Ascorbyl Glucoside', 'active', false, null, '{}'),
('3-O-Ethyl Ascorbic Acid', 'active', false, null, '{Ethyl Ascorbic Acid}'),
('Kojic Acid', 'active', false, null, '{}'),
('Resveratrol', 'active', false, null, '{}'),
('Ubiquinone', 'active', false, 'Coenzyme Q10', '{Coenzyme Q10,CoQ10}'),
('Ferulic Acid', 'active', false, null, '{}'),
('Beta-Glucan', 'active', false, null, '{}'),
('Avena Sativa Kernel Flour', 'active', false, 'Colloidal Oatmeal', '{Colloidal Oatmeal,Oat Kernel Flour}'),
('Panthenyl Ethyl Ether', 'active', false, null, '{}'),
-- thickeners
('Xanthan Gum', 'thickener', false, null, '{}'),
('Carbomer', 'thickener', false, null, '{}'),
('Hydroxyethylcellulose', 'thickener', false, null, '{}'),
('Sodium Polyacrylate', 'thickener', false, null, '{}'),
('Acrylates/C10-30 Alkyl Acrylate Crosspolymer', 'thickener', false, null, '{}'),
('Ammonium Acryloyldimethyltaurate/VP Copolymer', 'thickener', false, null, '{}'),
('Sclerotium Gum', 'thickener', false, null, '{}'),
('Cellulose Gum', 'thickener', false, null, '{}'),
('Silica', 'thickener', false, null, '{}'),
('Sodium Chloride', 'thickener', false, null, '{Salt}'),
('Polyacrylate Crosspolymer-6', 'thickener', false, null, '{}'),
('Hydroxypropyl Starch Phosphate', 'thickener', false, null, '{}'),
('Hydroxyethyl Acrylate/Sodium Acryloyldimethyl Taurate Copolymer', 'thickener', false, null, '{}'),
('Gellan Gum', 'thickener', false, null, '{}'),
('Magnesium Aluminum Silicate', 'thickener', false, null, '{}'),
('Microcrystalline Cellulose', 'thickener', false, null, '{}'),
-- antioxidants
('Tocopheryl Acetate', 'antioxidant', false, null, '{Vitamin E Acetate}'),
('Ascorbyl Palmitate', 'antioxidant', false, null, '{}'),
('BHT', 'antioxidant', false, null, '{}'),
('Ascorbyl Tetraisopalmitate', 'antioxidant', false, null, '{}'),
('Pentaerythrityl Tetra-di-t-Butyl Hydroxyhydrocinnamate', 'antioxidant', false, null, '{}'),
-- chelators
('Disodium EDTA', 'chelator', false, null, '{EDTA,Disodium Edetate,EDTA Disodium}'),
('Sodium Phytate', 'chelator', false, null, '{}'),
('Tetrasodium Glutamate Diacetate', 'chelator', false, null, '{}'),
('Trisodium Ethylenediamine Disuccinate', 'chelator', false, null, '{}'),
('Tetrasodium EDTA', 'chelator', false, null, '{}'),
('Phytic Acid', 'chelator', false, null, '{}'),
('Sodium Gluconate', 'chelator', false, null, '{}'),
-- pH adjusters
('Citric Acid', 'ph_adjuster', false, null, '{}'),
('Sodium Hydroxide', 'ph_adjuster', false, null, '{Caustic Soda}'),
('Sodium Citrate', 'ph_adjuster', false, null, '{}'),
('Triethanolamine', 'ph_adjuster', false, null, '{TEA}'),
('Arginine', 'ph_adjuster', false, null, '{}'),
('Potassium Hydroxide', 'ph_adjuster', false, null, '{}'),
('Aminomethyl Propanol', 'ph_adjuster', false, null, '{}'),
('Tromethamine', 'ph_adjuster', false, null, '{}'),
-- preservatives
('Phenoxyethanol', 'preservative', false, null, '{}'),
('Ethylhexylglycerin', 'preservative', false, null, '{}'),
('Sodium Benzoate', 'preservative', false, null, '{}'),
('Potassium Sorbate', 'preservative', false, null, '{}'),
('Caprylyl Glycol', 'preservative', false, null, '{}'),
('1,2-Hexanediol', 'preservative', false, null, '{1,2 Hexanediol,Hexanediol}'),
('Chlorphenesin', 'preservative', false, null, '{}'),
('Dehydroacetic Acid', 'preservative', false, null, '{}'),
('Benzoic Acid', 'preservative', false, null, '{}'),
('Sorbic Acid', 'preservative', false, null, '{}'),
('Benzyl Alcohol', 'preservative', true, null, '{}'),
('Methylparaben', 'preservative', false, null, '{}'),
('Propylparaben', 'preservative', false, null, '{}'),
('Hydroxyacetophenone', 'preservative', false, null, '{}'),
('Sodium Levulinate', 'preservative', false, null, '{}'),
('Sodium Anisate', 'preservative', false, null, '{}'),
('Glyceryl Caprylate', 'preservative', false, null, '{}'),
('Methylisothiazolinone', 'preservative', true, null, '{MIT}'),
('Methylchloroisothiazolinone', 'preservative', true, null, '{CMIT}'),
-- fragrance + EU-declarable fragrance allergens
('Parfum', 'fragrance', true, 'Fragrance', '{Fragrance,Perfume,Parfum/Fragrance,Fragrance/Parfum,Parfum (Fragrance),Fragrance (Parfum)}'),
('Linalool', 'allergen', true, null, '{}'),
('Limonene', 'allergen', true, null, '{D-Limonene}'),
('Citronellol', 'allergen', true, null, '{}'),
('Geraniol', 'allergen', true, null, '{}'),
('Hexyl Cinnamal', 'allergen', true, null, '{}'),
('Benzyl Salicylate', 'allergen', true, null, '{}'),
('Citral', 'allergen', true, null, '{}'),
('Coumarin', 'allergen', true, null, '{}'),
('Eugenol', 'allergen', true, null, '{}'),
('Benzyl Benzoate', 'allergen', true, null, '{}'),
('Alpha-Isomethyl Ionone', 'allergen', true, null, '{}'),
('Farnesol', 'allergen', true, null, '{}'),
('Amyl Cinnamal', 'allergen', true, null, '{}'),
('Cinnamyl Alcohol', 'allergen', true, null, '{}'),
('Isoeugenol', 'allergen', true, null, '{}'),
('Benzyl Cinnamate', 'allergen', true, null, '{}'),
('Anise Alcohol', 'allergen', true, null, '{}'),
('Hydroxycitronellal', 'allergen', true, null, '{}'),
-- colorants
('Mica', 'colorant', false, null, '{}'),
('CI 77891', 'colorant', false, 'Titanium Dioxide (pigment)', '{Titanium Dioxide (CI 77891),CI77891}'),
('CI 77491', 'colorant', false, 'Red Iron Oxide', '{Iron Oxides (CI 77491),Red Iron Oxide,CI77491}'),
('CI 77492', 'colorant', false, 'Yellow Iron Oxide', '{Iron Oxides (CI 77492),Yellow Iron Oxide}'),
('CI 77499', 'colorant', false, 'Black Iron Oxide', '{Iron Oxides (CI 77499),Black Iron Oxide}'),
('CI 19140', 'colorant', false, 'Yellow 5', '{Yellow 5}'),
('CI 42090', 'colorant', false, 'Blue 1', '{Blue 1}'),
('CI 17200', 'colorant', false, 'Red 33', '{Red 33}'),
('CI 15985', 'colorant', false, 'Yellow 6', '{Yellow 6}'),
('CI 14700', 'colorant', false, 'Red 4', '{Red 4}'),
('CI 60730', 'colorant', false, 'Ext. Violet 2', '{}'),
-- UV filters
('Zinc Oxide', 'uv_mineral', false, null, '{Zinc Oxide (Nano),Zinc Oxide [Nano]}'),
('Titanium Dioxide', 'uv_mineral', false, null, '{Titanium Dioxide (Nano),Titanium Dioxide [Nano]}'),
('Ethylhexyl Methoxycinnamate', 'uv_chemical', false, 'Octinoxate', '{Octinoxate,Octyl Methoxycinnamate}'),
('Butyl Methoxydibenzoylmethane', 'uv_chemical', false, 'Avobenzone', '{Avobenzone}'),
('Octocrylene', 'uv_chemical', false, null, '{}'),
('Homosalate', 'uv_chemical', false, null, '{}'),
('Ethylhexyl Salicylate', 'uv_chemical', false, 'Octisalate', '{Octisalate}'),
('Bis-Ethylhexyloxyphenol Methoxyphenyl Triazine', 'uv_chemical', false, 'Bemotrizinol', '{Bemotrizinol,Tinosorb S}'),
('Diethylamino Hydroxybenzoyl Hexyl Benzoate', 'uv_chemical', false, null, '{Uvinul A Plus}'),
('Ethylhexyl Triazone', 'uv_chemical', false, null, '{}'),
('Methylene Bis-Benzotriazolyl Tetramethylbutylphenol', 'uv_chemical', false, 'Bisoctrizole', '{Tinosorb M,Bisoctrizole}');

-- Botanicals: latin | common | parts. Expanded to "<Latin> <Part>" INCI names
-- with two label variants each: "<Common> <Part>" and "<Latin> (<Common>) <Part>".
create table synthetic.botanicals (latin text primary key, common text not null, parts text[] not null);
insert into synthetic.botanicals values
('Aloe Barbadensis', 'Aloe Vera', '{Leaf Juice,Leaf Extract}'),
('Camellia Sinensis', 'Green Tea', '{Leaf Extract,Leaf Water,Seed Oil}'),
('Chamomilla Recutita', 'Chamomile', '{Flower Extract,Flower Water}'),
('Glycyrrhiza Glabra', 'Licorice', '{Root Extract}'),
('Centella Asiatica', 'Cica', '{Extract,Leaf Extract,Leaf Water}'),
('Rosmarinus Officinalis', 'Rosemary', '{Leaf Extract,Leaf Oil}'),
('Calendula Officinalis', 'Calendula', '{Flower Extract,Flower Oil}'),
('Hamamelis Virginiana', 'Witch Hazel', '{Water,Leaf Extract,Bark Extract}'),
('Lavandula Angustifolia', 'Lavender', '{Oil,Flower Extract,Flower Water}'),
('Citrus Aurantium Dulcis', 'Orange', '{Peel Oil,Fruit Extract,Fruit Water}'),
('Citrus Limon', 'Lemon', '{Peel Oil,Fruit Extract}'),
('Melaleuca Alternifolia', 'Tea Tree', '{Leaf Oil,Leaf Extract}'),
('Vitis Vinifera', 'Grape', '{Seed Extract,Fruit Extract,Seed Oil}'),
('Cucumis Sativus', 'Cucumber', '{Fruit Extract,Fruit Water}'),
('Panax Ginseng', 'Ginseng', '{Root Extract}'),
('Avena Sativa', 'Oat', '{Kernel Extract,Kernel Oil,Bran Extract}'),
('Oryza Sativa', 'Rice', '{Bran Oil,Bran Extract,Extract,Starch}'),
('Hibiscus Sabdariffa', 'Hibiscus', '{Flower Extract}'),
('Rosa Damascena', 'Rose', '{Flower Water,Flower Oil,Flower Extract}'),
('Rosa Canina', 'Rosehip', '{Fruit Oil,Fruit Extract}'),
('Punica Granatum', 'Pomegranate', '{Fruit Extract,Seed Oil}'),
('Curcuma Longa', 'Turmeric', '{Root Extract}'),
('Zingiber Officinale', 'Ginger', '{Root Extract,Root Oil}'),
('Mentha Piperita', 'Peppermint', '{Oil,Leaf Extract}'),
('Eucalyptus Globulus', 'Eucalyptus', '{Leaf Oil,Leaf Extract}'),
('Salvia Officinalis', 'Sage', '{Leaf Extract,Oil}'),
('Thymus Vulgaris', 'Thyme', '{Leaf Extract,Flower/Leaf Oil}'),
('Ginkgo Biloba', 'Ginkgo', '{Leaf Extract}'),
('Morus Alba', 'White Mulberry', '{Root Extract,Leaf Extract}'),
('Paeonia Albiflora', 'Peony', '{Root Extract}'),
('Magnolia Officinalis', 'Magnolia', '{Bark Extract}'),
('Nelumbo Nucifera', 'Lotus', '{Flower Extract,Leaf Extract}'),
('Moringa Oleifera', 'Moringa', '{Seed Oil,Leaf Extract}'),
('Adansonia Digitata', 'Baobab', '{Seed Oil,Fruit Extract}'),
('Sclerocarya Birrea', 'Marula', '{Seed Oil}'),
('Opuntia Ficus-Indica', 'Prickly Pear', '{Seed Oil,Stem Extract}'),
('Hippophae Rhamnoides', 'Sea Buckthorn', '{Fruit Oil,Seed Oil,Fruit Extract}'),
('Bambusa Vulgaris', 'Bamboo', '{Leaf Extract,Water}'),
('Cannabis Sativa', 'Hemp', '{Seed Oil}'),
('Linum Usitatissimum', 'Flax', '{Seed Oil,Seed Extract}'),
('Carthamus Tinctorius', 'Safflower', '{Seed Oil}'),
('Crambe Abyssinica', 'Crambe', '{Seed Oil}'),
('Mangifera Indica', 'Mango', '{Seed Butter,Fruit Extract}'),
('Shorea Robusta', 'Sal', '{Seed Butter}'),
('Ananas Sativus', 'Pineapple', '{Fruit Extract}'),
('Carica Papaya', 'Papaya', '{Fruit Extract}'),
('Vaccinium Macrocarpon', 'Cranberry', '{Fruit Extract,Seed Oil}'),
('Vaccinium Myrtillus', 'Bilberry', '{Fruit/Leaf Extract}'),
('Rubus Idaeus', 'Raspberry', '{Seed Oil,Fruit Extract}'),
('Fragaria Vesca', 'Strawberry', '{Fruit Extract}'),
('Prunus Persica', 'Peach', '{Leaf Extract,Kernel Oil}'),
('Pyrus Malus', 'Apple', '{Fruit Extract}'),
('Citrus Paradisi', 'Grapefruit', '{Peel Oil,Fruit Extract}'),
('Citrus Reticulata', 'Mandarin', '{Peel Oil}'),
('Citrus Bergamia', 'Bergamot', '{Peel Oil}'),
('Pelargonium Graveolens', 'Geranium', '{Flower Oil}'),
('Jasminum Officinale', 'Jasmine', '{Flower Extract,Oil}'),
('Santalum Album', 'Sandalwood', '{Oil,Wood Extract}'),
('Cedrus Atlantica', 'Cedarwood', '{Bark Oil}'),
('Pogostemon Cablin', 'Patchouli', '{Oil}'),
('Vanilla Planifolia', 'Vanilla', '{Fruit Extract}'),
('Coffea Arabica', 'Coffee', '{Seed Extract,Seed Oil}'),
('Arnica Montana', 'Arnica', '{Flower Extract}'),
('Echinacea Purpurea', 'Echinacea', '{Extract}'),
('Equisetum Arvense', 'Horsetail', '{Extract}'),
('Urtica Dioica', 'Nettle', '{Leaf Extract}'),
('Achillea Millefolium', 'Yarrow', '{Extract}'),
('Symphytum Officinale', 'Comfrey', '{Leaf Extract}'),
('Plantago Lanceolata', 'Plantain', '{Leaf Extract}'),
('Laminaria Digitata', 'Kelp', '{Extract}'),
('Fucus Vesiculosus', 'Bladderwrack', '{Extract}'),
('Chlorella Vulgaris', 'Chlorella', '{Extract}'),
('Spirulina Platensis', 'Spirulina', '{Extract}'),
('Undaria Pinnatifida', 'Wakame', '{Extract}'),
('Pueraria Lobata', 'Kudzu', '{Root Extract}'),
('Polygonum Cuspidatum', 'Japanese Knotweed', '{Root Extract}'),
('Scutellaria Baicalensis', 'Baikal Skullcap', '{Root Extract}'),
('Houttuynia Cordata', 'Houttuynia', '{Extract}'),
('Artemisia Vulgaris', 'Mugwort', '{Extract}'),
('Portulaca Oleracea', 'Purslane', '{Extract}'),
('Lycium Barbarum', 'Goji', '{Fruit Extract}'),
('Schisandra Chinensis', 'Schisandra', '{Fruit Extract}'),
('Ficus Carica', 'Fig', '{Fruit Extract}'),
('Glycine Soja', 'Soybean', '{Oil,Seed Extract}'),
('Zea Mays', 'Corn', '{Starch,Kernel Oil}'),
('Solanum Lycopersicum', 'Tomato', '{Fruit Extract}'),
('Daucus Carota Sativa', 'Carrot', '{Root Extract,Seed Oil}'),
('Calophyllum Inophyllum', 'Tamanu', '{Seed Oil}'),
('Bixa Orellana', 'Annatto', '{Seed Extract}'),
('Tamarindus Indica', 'Tamarind', '{Seed Extract}'),
('Terminalia Ferdinandiana', 'Kakadu Plum', '{Fruit Extract}'),
('Psoralea Corylifolia', 'Bakuchi', '{Seed Extract}'),
('Lens Esculenta', 'Lentil', '{Fruit Extract}'),
('Tremella Fuciformis', 'Snow Mushroom', '{Sporocarp Extract}'),
('Ganoderma Lucidum', 'Reishi', '{Stem Extract}');

create table synthetic.brand_names (ord int generated always as identity, name text primary key);
insert into synthetic.brand_names (name) values
('Velvane Skin'), ('Northfern'), ('Aurelith'), ('Kaorin & Co'), ('Driftmere Apothecary'), ('Halcyra'),
('Petalwright'), ('Saltglass'), ('Ondessa Hair'), ('Clearwell Derm'), ('Oat & Ember'), ('Nimbrae'),
('Lunaveil'), ('Brightmoss'), ('Tessavine'), ('Corvella'), ('Hollowreed'), ('Isomara'), ('Junipel'),
('Kestral Skin'), ('Lirabelle'), ('Mirelune'), ('Nouvra'), ('Opaline Field'), ('Pellucid Lab'), ('Rivulet'),
('Sablewood'), ('Tidewell'), ('Umbrelle'), ('Verdantia'), ('Wrenfield'), ('Yarrowby'), ('Zephyrine'),
('Ambrose & Hale'), ('Bramblewick'), ('Calder Skin'), ('Dovetail Hair'), ('Elmstead'), ('Fennick'),
('Gloamwood'), ('Heathermoor'), ('Ivorine'), ('Jessamy'), ('Kindlepeak'), ('Larkspire'), ('Mossgate'),
('Quillon Labs'), ('Starling Bare');

-- product types -> formula family + label names
create table synthetic.product_types (
  ord int generated always as identity,
  product_type text primary key,
  category text not null,
  family text not null,
  names text[] not null
);
insert into synthetic.product_types (product_type, category, family, names) values
('cleanser', 'skincare', 'cleanser', '{Hydrating Facial Cleanser,Gentle Foaming Cleanser,Cream Cleanser,Gel Cleanser,Balancing Face Wash,Micellar Cleansing Water}'),
('serum', 'skincare', 'serum', '{Niacinamide 10% Serum,Hyaluronic Hydration Serum,Brightening Vitamin C Serum,Retinol Night Serum,Peptide Firming Serum,Barrier Repair Serum}'),
('moisturizer', 'skincare', 'emulsion', '{Daily Moisture Cream,Barrier Repair Moisturizer,Oil-Free Gel Moisturizer,Rich Night Cream,Ceramide Recovery Cream,Lightweight Day Lotion}'),
('toner', 'skincare', 'serum', '{Exfoliating Toner,Hydrating Essence Toner,Calming Toner,Pore Refining Tonic}'),
('mask', 'skincare', 'emulsion', '{Overnight Recovery Mask,Clay Purifying Mask,Hydrating Sleeping Mask}'),
('eye_cream', 'skincare', 'emulsion', '{Brightening Eye Cream,Peptide Eye Gel}'),
('cleansing_balm', 'skincare', 'balm', '{Melting Cleansing Balm}'),
('sunscreen_mineral', 'suncare', 'sun_mineral', '{Mineral Sunscreen SPF 30,Tinted Mineral SPF 50}'),
('sunscreen_chemical', 'suncare', 'sun_chemical', '{Daily UV Fluid SPF 50,Sport Sun Lotion SPF 30}'),
('shampoo', 'haircare', 'shampoo', '{Clarifying Shampoo,Hydrating Shampoo,Volumizing Shampoo,Anti-Dandruff Shampoo,Color Care Shampoo}'),
('conditioner', 'haircare', 'conditioner', '{Repair Conditioner,Lightweight Conditioner,Curl Conditioner,Deep Moisture Conditioner}'),
('hair_mask', 'haircare', 'conditioner', '{Bond Repair Hair Mask,Intensive Hair Masque}'),
('styling', 'haircare', 'conditioner', '{Curl Defining Cream,Leave-In Conditioning Spray,Smoothing Hair Serum}'),
('scalp', 'haircare', 'serum', '{Scalp Treatment Serum,Soothing Scalp Tonic}'),
('body_lotion', 'bodycare', 'emulsion', '{Daily Body Lotion,Firming Body Cream,Shea Body Butter}'),
('body_wash', 'bodycare', 'cleanser', '{Nourishing Body Wash,Exfoliating Shower Gel}'),
('hand_cream', 'bodycare', 'emulsion', '{Repair Hand Cream}'),
('lip_balm', 'bodycare', 'balm', '{Lip Conditioning Balm}');

create table synthetic.name_lines (ord int generated always as identity, line text primary key);
insert into synthetic.name_lines (line) values
('Daily'), ('Calm'), ('Glow'), ('Barrier'), ('Pure'), ('Aqua'), ('Clear'), ('Bloom'), ('Renew'), ('Velvet'),
('Cica'), ('Oat'), ('Rice'), ('Marine'), ('Botanic'), ('Night'), ('Sensitive'), ('Balance'), ('Radiance'), ('Hydra');

-- Formula families: ordered slots of (pool, min, max). Label order follows slot order.
create table synthetic.family_slots (
  family text not null,
  slot int not null,
  pool text not null,
  min_n int not null,
  max_n int not null,
  primary key (family, slot)
);
insert into synthetic.family_slots values
('cleanser', 1, 'solvent', 1, 1), ('cleanser', 2, 'surfactant', 2, 4), ('cleanser', 3, 'humectant', 2, 3),
('cleanser', 4, 'emollient', 0, 2), ('cleanser', 5, 'active', 1, 2), ('cleanser', 6, 'extract', 2, 4),
('cleanser', 7, 'extract_tail', 1, 2), ('cleanser', 8, 'thickener', 1, 2), ('cleanser', 9, 'antioxidant', 0, 1),
('cleanser', 10, 'chelator', 1, 1), ('cleanser', 11, 'ph_adjuster', 1, 2), ('cleanser', 12, 'preservative', 2, 3),
('cleanser', 13, 'fragrance', 0, 1), ('cleanser', 14, 'allergen', 0, 3),

('serum', 1, 'solvent', 1, 1), ('serum', 2, 'humectant', 3, 5), ('serum', 3, 'active', 2, 3),
('serum', 4, 'active_tail', 1, 3), ('serum', 5, 'extract', 1, 3), ('serum', 6, 'extract_tail', 1, 3),
('serum', 7, 'emollient', 0, 2), ('serum', 8, 'thickener', 1, 2), ('serum', 9, 'antioxidant', 1, 2),
('serum', 10, 'chelator', 1, 1), ('serum', 11, 'ph_adjuster', 1, 2), ('serum', 12, 'preservative', 2, 3),
('serum', 13, 'fragrance', 0, 1), ('serum', 14, 'allergen', 0, 2),

('emulsion', 1, 'solvent', 1, 1), ('emulsion', 2, 'humectant', 2, 4), ('emulsion', 3, 'emollient', 3, 5),
('emulsion', 4, 'emollient_tail', 1, 2), ('emulsion', 5, 'emulsifier', 2, 4), ('emulsion', 6, 'emulsifier_tail', 0, 1),
('emulsion', 7, 'active', 1, 3), ('emulsion', 8, 'active_tail', 0, 2), ('emulsion', 9, 'extract', 1, 3),
('emulsion', 10, 'extract_tail', 0, 2), ('emulsion', 11, 'thickener', 1, 2), ('emulsion', 12, 'antioxidant', 1, 2),
('emulsion', 13, 'chelator', 1, 1), ('emulsion', 14, 'ph_adjuster', 1, 1), ('emulsion', 15, 'preservative', 2, 3),
('emulsion', 16, 'fragrance', 0, 1), ('emulsion', 17, 'allergen', 0, 3),

('balm', 1, 'emollient', 4, 7), ('balm', 2, 'emollient_tail', 1, 3), ('balm', 3, 'emulsifier', 1, 2),
('balm', 4, 'extract', 1, 3), ('balm', 5, 'extract_tail', 1, 2), ('balm', 6, 'antioxidant', 1, 2),
('balm', 7, 'fragrance', 0, 1), ('balm', 8, 'allergen', 0, 2), ('balm', 9, 'colorant', 0, 2),

('sun_mineral', 1, 'solvent', 1, 1), ('sun_mineral', 2, 'uv_mineral', 1, 2), ('sun_mineral', 3, 'emollient', 3, 5),
('sun_mineral', 4, 'humectant', 1, 3), ('sun_mineral', 5, 'emulsifier', 2, 3), ('sun_mineral', 6, 'thickener', 1, 3),
('sun_mineral', 7, 'active', 0, 2), ('sun_mineral', 8, 'extract', 1, 2), ('sun_mineral', 9, 'antioxidant', 1, 2),
('sun_mineral', 10, 'chelator', 0, 1), ('sun_mineral', 11, 'preservative', 2, 3), ('sun_mineral', 12, 'colorant', 0, 3),

('sun_chemical', 1, 'solvent', 1, 1), ('sun_chemical', 2, 'uv_chemical', 3, 5), ('sun_chemical', 3, 'emollient', 2, 4),
('sun_chemical', 4, 'humectant', 1, 3), ('sun_chemical', 5, 'emulsifier', 1, 3), ('sun_chemical', 6, 'thickener', 1, 2),
('sun_chemical', 7, 'active', 0, 2), ('sun_chemical', 8, 'extract', 1, 2), ('sun_chemical', 9, 'antioxidant', 1, 2),
('sun_chemical', 10, 'chelator', 1, 1), ('sun_chemical', 11, 'ph_adjuster', 0, 1), ('sun_chemical', 12, 'preservative', 2, 3),
('sun_chemical', 13, 'fragrance', 0, 1), ('sun_chemical', 14, 'allergen', 0, 2),

('shampoo', 1, 'solvent', 1, 1), ('shampoo', 2, 'surfactant', 3, 4), ('shampoo', 3, 'conditioning', 1, 3),
('shampoo', 4, 'humectant', 1, 2), ('shampoo', 5, 'active', 0, 2), ('shampoo', 6, 'extract', 2, 4),
('shampoo', 7, 'extract_tail', 1, 2), ('shampoo', 8, 'thickener', 1, 2), ('shampoo', 9, 'chelator', 1, 1),
('shampoo', 10, 'ph_adjuster', 1, 2), ('shampoo', 11, 'preservative', 2, 3), ('shampoo', 12, 'fragrance', 1, 1),
('shampoo', 13, 'allergen', 1, 4), ('shampoo', 14, 'colorant', 0, 1),

('conditioner', 1, 'solvent', 1, 1), ('conditioner', 2, 'emulsifier', 2, 3), ('conditioner', 3, 'conditioning', 2, 4),
('conditioner', 4, 'emollient', 2, 4), ('conditioner', 5, 'emollient_tail', 0, 2), ('conditioner', 6, 'humectant', 1, 3),
('conditioner', 7, 'active', 0, 2), ('conditioner', 8, 'extract', 1, 3), ('conditioner', 9, 'extract_tail', 1, 2),
('conditioner', 10, 'antioxidant', 0, 1), ('conditioner', 11, 'chelator', 0, 1), ('conditioner', 12, 'ph_adjuster', 1, 1),
('conditioner', 13, 'preservative', 2, 3), ('conditioner', 14, 'fragrance', 1, 1), ('conditioner', 15, 'allergen', 1, 4);

-- ---------------------------------------------------------------------------
-- Dictionary loader (idempotent): curated + aliases, botanicals, and the long
-- tail of systematic INCI names real catalogs accumulate.
-- ---------------------------------------------------------------------------
create or replace function synthetic.load_dictionary()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_before int;
begin
  select count(*) into v_before from public.ingredients;

  insert into public.ingredients (inci_name, normalized_name, common_name, function, is_allergen, origin)
  select c.inci, public.normalize_inci(c.inci), c.common_name, c.fn, c.allergen, 'curated'
  from synthetic.curated_inci c
  order by c.ord
  on conflict (normalized_name) do nothing;

  insert into public.ingredient_aliases (alias_normalized, alias, ingredient_id, origin)
  select distinct on (public.normalize_inci(a.alias)) public.normalize_inci(a.alias), a.alias, i.id, 'curated'
  from synthetic.curated_inci c
  cross join lateral unnest(c.aliases) as a (alias)
  join public.ingredients i on i.normalized_name = public.normalize_inci(c.inci)
  where not exists (select 1 from public.ingredients x where x.normalized_name = public.normalize_inci(a.alias))
  order by public.normalize_inci(a.alias), c.ord
  on conflict (alias_normalized) do nothing;

  -- Botanicals
  insert into public.ingredients (inci_name, normalized_name, common_name, function, origin)
  select b.latin || ' ' || p.part, public.normalize_inci(b.latin || ' ' || p.part), b.common || ' ' || p.part,
         case when p.part ~* '(oil|butter)$' then 'emollient' else 'extract' end, 'synthetic'
  from synthetic.botanicals b cross join lateral unnest(b.parts) as p (part)
  where not exists (select 1 from public.ingredient_aliases a where a.alias_normalized = public.normalize_inci(b.latin || ' ' || p.part))
  on conflict (normalized_name) do nothing;

  insert into public.ingredient_aliases (alias_normalized, alias, ingredient_id, origin)
  select distinct on (public.normalize_inci(v.alias)) public.normalize_inci(v.alias), v.alias, i.id, 'synthetic'
  from synthetic.botanicals b
  cross join lateral unnest(b.parts) as p (part)
  cross join lateral (values (b.common || ' ' || p.part), (b.latin || ' (' || b.common || ') ' || p.part)) as v (alias)
  join public.ingredients i on i.normalized_name = public.normalize_inci(b.latin || ' ' || p.part)
  where not exists (select 1 from public.ingredients x where x.normalized_name = public.normalize_inci(v.alias))
  order by public.normalize_inci(v.alias)
  on conflict (alias_normalized) do nothing;

  -- Systematic long tail
  with tail (inci, fn) as (
    select 'PEG-' || n || ' ' || e, 'emulsifier'
    from unnest('{4,6,7,8,12,20,30,40,60,75,80,100,120,150,200}'::int[]) n,
         unnest('{Stearate,Laurate,Oleate,Dilaurate,Distearate,Glyceryl Cocoate,Hydrogenated Castor Oil,Sorbitan Isostearate}'::text[]) e
    union all
    select 'Polyquaternium-' || n, 'conditioning' from generate_series(1, 80) n
    union all
    select e || '-' || n, 'emulsifier'
    from unnest('{Ceteareth,Laureth,Steareth,Oleth,Ceteth}'::text[]) e, generate_series(2, 30, 2) n
    union all
    select 'Polysorbate ' || n, 'emulsifier' from unnest('{21,40,61,65,80,81,85}'::int[]) n
    union all
    select pfx || ' ' || pep || '-' || n, 'active'
    from unnest('{Palmitoyl,Acetyl,Myristoyl}'::text[]) pfx,
         unnest('{Dipeptide,Tripeptide,Tetrapeptide,Pentapeptide,Hexapeptide,Oligopeptide}'::text[]) pep,
         generate_series(1, 40) n
    union all
    select 'Hydrolyzed ' || x, 'conditioning'
    from unnest('{Silk,Collagen,Rice Protein,Soy Protein,Oat Protein,Quinoa,Pea Protein,Corn Protein,Milk Protein,Elastin,Yeast Protein,Sweet Almond Protein,Jojoba Esters,Vegetable Protein}'::text[]) x
    union all
    select a || ' ' || b, 'emollient'
    from unnest('{Isopropyl,Ethylhexyl,Cetyl,Myristyl,Octyldodecyl,Isostearyl,Decyl,Isodecyl,Butyl,Hexyl,Isononyl,Isotridecyl,Cetearyl,Stearyl,Oleyl,Lauryl,Behenyl,Isocetyl,Diisopropyl,Tridecyl}'::text[]) a,
         unnest('{Myristate,Palmitate,Stearate,Isostearate,Laurate,Oleate,Neopentanoate,Isononanoate,Ethylhexanoate,Lactate,Benzoate,Adipate,Sebacate,Succinate,Erucate,Linoleate}'::text[]) b
    union all
    select 'CI ' || n, 'colorant'
    from unnest('{10006,10020,11680,11710,12085,12490,15510,15850,15880,16035,16185,16255,17200,19140,20470,26100,40800,42053,42510,45100,45380,45410,47000,61565,73360,74160,75120,75130,75470,77000,77002,77004,77163,77220,77266,77288,77289,77400,77480,77510,77742,77820,77947}'::text[]) n
  )
  insert into public.ingredients (inci_name, normalized_name, function, origin)
  select t.inci, public.normalize_inci(t.inci), t.fn, 'synthetic'
  from tail t
  where not exists (select 1 from public.ingredient_aliases a where a.alias_normalized = public.normalize_inci(t.inci))
  on conflict (normalized_name) do nothing;

  return jsonb_build_object('ingredients_added', (select count(*) from public.ingredients) - v_before,
                            'ingredients', (select count(*) from public.ingredients),
                            'aliases', (select count(*) from public.ingredient_aliases));
end;
$$;

create or replace function synthetic.h(p text, p_seed int)
returns bigint
language sql
immutable
set search_path = ''
as $$ select abs(hashtextextended(p, p_seed)) $$;

-- uniform [0,1)
create or replace function synthetic.u(p text, p_seed int)
returns double precision
language sql
immutable
set search_path = ''
as $$ select (abs(hashtextextended(p, p_seed)) % 1000000) / 1000000.0 $$;

-- ---------------------------------------------------------------------------
-- Catalog generator
-- ---------------------------------------------------------------------------
create or replace function synthetic.generate_catalog(p_products int, p_seed int default 42)
returns jsonb
language plpgsql
set search_path = ''
set statement_timeout = 0
as $$
declare
  v_started timestamptz := clock_timestamp();
  v_brands int;
  v_offset bigint;
  v_rows bigint;
begin
  perform synthetic.load_dictionary();

  -- brands + their sites, plus retailers
  insert into public.brands (name, slug, website)
  select b.name, btrim(regexp_replace(lower(b.name), '[^a-z0-9]+', '-', 'g'), '-'),
         'https://' || btrim(regexp_replace(lower(b.name), '[^a-z0-9]+', '-', 'g'), '-') || '.example'
  from synthetic.brand_names b order by b.ord
  on conflict (name) do nothing;
  select count(*) into v_brands from public.brands;

  insert into public.sources (domain, name, kind, trust_level, rate_limit_per_min)
  select substring(b.website from '^https://(.*)$'), b.name || ' (brand site)', 'brand_site',
         case when synthetic.h(b.slug, p_seed) % 10 < 8 then 'trusted'::public.trust_level else 'unverified' end, 30
  from public.brands b where b.website is not null
  on conflict (domain) do nothing;

  insert into public.sources (domain, name, kind, trust_level, rate_limit_per_min) values
    ('glowmart.example', 'GlowMart (retailer)', 'retailer', 'trusted', 60),
    ('beautyaisle.example', 'Beauty Aisle (retailer)', 'retailer', 'unverified', 20),
    ('dermadeals.example', 'DermaDeals (marketplace)', 'retailer', 'suspect', 10),
    ('inci-registry.example', 'INCI registry (reference)', 'regulatory', 'trusted', 120)
  on conflict (domain) do nothing;

  insert into private.url_check_mock (domain, http_status, tls_ok, final_domain) values
    ('beautyaisle.example', 200, true, 'beautyaisle-outlet.example'),
    ('dermadeals.example', 503, true, null),
    ('hollowreed.example', 200, false, null)
  on conflict (domain) do nothing;

  -- pools: popular-first ordering within each function; *_tail = systematic names
  create temp table tmp_pool on commit drop as
  select pool, row_number() over (partition by pool order by ord, id) as idx, id as ingredient_id
  from (
    select i.id,
           case when i.function = 'extract'
                  then case when synthetic.h(i.id::text, p_seed) % 3 = 0 then 'extract_tail' else 'extract' end
                when i.origin = 'synthetic' and i.function in ('emollient', 'emulsifier', 'active', 'conditioning')
                  then i.function || '_tail'
                else i.function end as pool,
           coalesce(c.ord, 100000 + i.id) as ord
    from public.ingredients i
    left join synthetic.curated_inci c on public.normalize_inci(c.inci) = i.normalized_name
    where i.function is not null
  ) x;
  create temp table tmp_pool_n on commit drop as select pool, count(*)::int as n from tmp_pool group by pool;

  -- products
  select coalesce(max(id), 0) into v_offset from public.products;

  create temp table tmp_products on commit drop as
  with g as (select g from generate_series(1, p_products) g),
  base as (
    select g.g,
           case when g.g % 250 = 0 and g.g > 1 then g.g - 1 else g.g end as formula_g,
           1 + synthetic.h('brand:' || (case when g.g % 250 = 0 and g.g > 1 then g.g - 1 else g.g end), p_seed) % v_brands as brand_ord,
           1 + synthetic.h('type:' || (case when g.g % 250 = 0 and g.g > 1 then g.g - 1 else g.g end), p_seed) % (select count(*) from synthetic.product_types) as type_ord,
           1 + synthetic.h('line:' || (case when g.g % 250 = 0 and g.g > 1 then g.g - 1 else g.g end), p_seed) % (select count(*) from synthetic.name_lines) as line_ord,
           synthetic.h('name:' || (case when g.g % 250 = 0 and g.g > 1 then g.g - 1 else g.g end), p_seed) as name_h,
           synthetic.h('status:' || g.g, p_seed) % 1000 as status_h,
           synthetic.h('prov:' || g.g, p_seed) % 100 as prov_h
    from g
  )
  select b.*, br.id as brand_id, br.slug as brand_slug, substring(br.website from '^https://(.*)$') as brand_domain,
         t.product_type, t.category, t.family,
         l.line || ' ' || t.names[1 + (b.name_h % cardinality(t.names))::int] as name,
         case when b.status_h < 970 then 'published' when b.status_h < 990 then 'draft' else 'archived' end::public.product_status as status,
         b.status_h between 960 and 963 as no_ingredients,
         b.g % 250 = 0 and b.g > 1 as is_duplicate
  from base b
  join (select id, slug, website, row_number() over (order by id) as ord from public.brands) br on br.ord = b.brand_ord
  join synthetic.product_types t on t.ord = b.type_ord
  join synthetic.name_lines l on l.ord = b.line_ord;

  insert into public.products (brand_id, name, category, product_type, product_url, source_id, status, published_at, created_at)
  select p.brand_id, p.name, p.category, p.product_type,
         case when p.is_duplicate
              then 'https://glowmart.example/p/' || p.brand_slug || '-' || regexp_replace(lower(p.name), '[^a-z0-9]+', '-', 'g') || '-' || (v_offset + p.g)
              else 'https://' || p.brand_domain || '/products/' || regexp_replace(lower(p.name), '[^a-z0-9]+', '-', 'g') || '-' || (v_offset + p.g) end,
         case when p.is_duplicate then (select id from public.sources where domain = 'glowmart.example')
              else (select id from public.sources where domain = p.brand_domain) end,
         p.status,
         case when p.status = 'published' then now() - make_interval(days => (synthetic.h('pub:' || p.g, p_seed) % 400)::int) end,
         now() - make_interval(days => (synthetic.h('pub:' || p.g, p_seed) % 400)::int + 3)
  from tmp_products p
  order by p.g;

  alter table tmp_products add column id bigint;
  update tmp_products t set id = p.id
  from (select id, substring(product_url from '-([0-9]+)$')::bigint - v_offset as g
        from public.products where id > v_offset) p
  where p.g = t.g;
  create index on tmp_products (id);
  analyze tmp_products;

  -- ingredient lists (bulk path: superuser-only, inside the write token)
  perform private.open_catalog_write();

  insert into public.product_ingredients
    (product_id, ingredient_id, position, raw_name, provenance_kind, source_id, source_url, scraped_at, confidence)
  select x.product_id, x.ingredient_id,
         row_number() over (partition by x.product_id order by x.slot, x.k)::smallint,
         i.inci_name,
         case
           when x.prov_h < 60 then 'scraped'
           when x.prov_h < 76 then 'verified'
           when x.prov_h < 84 then 'manual'
           when x.prov_h < 94 then case when synthetic.h('row:' || x.product_id || ':' || x.ingredient_id, p_seed) % 6 = 0 then 'ai_suggested' else 'scraped' end
           else case when synthetic.h('row:' || x.product_id || ':' || x.ingredient_id, p_seed) % 10 < 6 then 'ai_suggested' else 'scraped' end
         end::public.provenance_kind,
         x.source_id, x.product_url, x.scraped_at,
         round((0.90 + synthetic.u('conf:' || x.product_id || ':' || x.ingredient_id, p_seed) * 0.10)::numeric, 3)
  from (
    select distinct on (p.id, pl.ingredient_id)
           p.id as product_id, pl.ingredient_id, s.slot, k.k, p.prov_h, pr.source_id, pr.product_url,
           pr.created_at + interval '1 day' as scraped_at
    from tmp_products p
    join public.products pr on pr.id = p.id
    join synthetic.family_slots s on s.family = p.family
    cross join lateral generate_series(1, s.min_n + (synthetic.h('n:' || p.formula_g || ':' || s.slot, p_seed) % (s.max_n - s.min_n + 1))::int) k (k)
    join tmp_pool_n pn on pn.pool = s.pool
    join tmp_pool pl on pl.pool = s.pool
      and pl.idx = 1 + floor(pn.n * power(synthetic.u('pick:' || p.formula_g || ':' || s.slot || ':' || k.k, p_seed), 1.6))::int
    where not p.no_ingredients
    order by p.id, pl.ingredient_id, s.slot, k.k
  ) x
  join public.ingredients i on i.id = x.ingredient_id;
  get diagnostics v_rows = row_count;

  -- ai_suggested rows carry their (lower) model confidence
  update public.product_ingredients pi
     set confidence = round((0.55 + synthetic.u('aiconf:' || pi.product_id || ':' || pi.ingredient_id, p_seed) * 0.34)::numeric, 3),
         source_id = null, source_url = null, scraped_at = null
   where pi.provenance_kind = 'ai_suggested' and pi.product_id > v_offset;
  update public.product_ingredients pi
     set source_id = null, source_url = null, scraped_at = null, confidence = null
   where pi.provenance_kind in ('verified', 'manual') and pi.product_id > v_offset;

  update public.products p
     set ingredients_hash = x.h, ingredient_count = x.n
    from (select product_id, private.list_hash(array_agg(ingredient_id order by position)) as h, count(*)::int as n
          from public.product_ingredients where product_id > v_offset group by product_id) x
   where p.id = x.product_id;

  perform private.close_catalog_write();

  -- AI cache: current score + one narrative provider, plus invalidated history
  insert into public.analysis_cache (product_id, analysis_kind, provider, model, prompt_version, ingredients_hash, output,
                                     expires_at, created_at, invalidated_at, invalidated_reason, quarantined, quarantined_at, quarantine_reason)
  select p.id, v.kind, v.provider, v.model, v.prompt, v.hash,
         case when v.kind = 'ingredient_score'
              then jsonb_build_object('score', 40 + synthetic.h('score:' || p.id || v.prompt, p_seed) % 60,
                                      'allergens', (select count(*) from public.product_ingredients pi join public.ingredients i on i.id = pi.ingredient_id
                                                    where pi.product_id = p.id and i.is_allergen))
              else jsonb_build_object('summary', 'Synthetic ' || v.provider || ' narrative for ' || p.name || ' (' || v.prompt || ').') end,
         v.expires_at, v.created_at, v.invalidated_at, v.invalidated_reason,
         v.quarantined, case when v.quarantined then v.invalidated_at end, case when v.quarantined then 'ingredients_changed' end
  from public.products p
  cross join lateral (
    select synthetic.h('prov:' || p.id, p_seed) % 3 as np, synthetic.h('exp:' || p.id, p_seed) % 100 as eh,
           synthetic.h('q:' || p.id, p_seed) % 1000 as qh
  ) r
  cross join lateral (values
    ('ingredient_score', 'internal', 'scorer-4', 'v4', p.ingredients_hash,
       case when r.eh = 0 then now() - interval '2 days' else now() + interval '30 days' end,
       now() - interval '5 days', null::timestamptz, null::text, false),
    ('safety_narrative', (array['anthropic', 'openai', 'google'])[1 + r.np], (array['claude-sonnet-5-5', 'gpt-5-mini', 'gemini-2.5-flash'])[1 + r.np], 'v3',
       p.ingredients_hash, now() + interval '30 days', now() - interval '5 days', null, null, false),
    ('ingredient_score', 'internal', 'scorer-3', 'v3', p.ingredients_hash, now() - interval '60 days',
       now() - interval '120 days', now() - interval '20 days', 'prompt_version_bumped', false),
    ('safety_narrative', (array['anthropic', 'openai', 'google'])[1 + r.np], (array['claude-sonnet-5-5', 'gpt-5-mini', 'gemini-2.5-flash'])[1 + r.np], 'v2',
       p.ingredients_hash, now() - interval '60 days', now() - interval '120 days', now() - interval '20 days', 'prompt_version_bumped', false),
    ('routine_narrative', (array['openai', 'google', 'anthropic'])[1 + r.np], (array['gpt-5-mini', 'gemini-2.5-flash', 'claude-sonnet-5-5'])[1 + r.np], 'v1',
       md5(p.id || ':old'), now() - interval '10 days', now() - interval '40 days', now() - interval '12 days', 'ingredients_changed', r.qh < 4)
  ) as v (kind, provider, model, prompt, hash, expires_at, created_at, invalidated_at, invalidated_reason, quarantined)
  where p.id > v_offset and p.status = 'published' and p.ingredients_hash is not null;

  -- Verification backlog: messy label names (history resolved; recent ones pending)
  create temp table tmp_messy on commit drop as
  select m.raw, public.normalize_inci(m.raw) as norm, m.resolves_to,
         (select t.id from (
            select i.id, extensions.similarity(i.normalized_name, public.normalize_inci(m.raw)) as s from public.ingredients i
            union all
            select a.ingredient_id, extensions.similarity(a.alias_normalized, public.normalize_inci(m.raw)) from public.ingredient_aliases a
          ) t order by t.s desc limit 1) as suggested,
         row_number() over () as k
  from (values
    ('Glycerine (Vegetable)', 'Glycerin'), ('Squalene', 'Squalane'), ('Niacinamid', 'Niacinamide'),
    ('Tocopheryl Acetat', 'Tocopheryl Acetate'), ('Phenoxyethanol & Ethylhexylglycerin', null),
    ('Essential Oil Blend', null), ('Natural Fragrance', 'Parfum'), ('Botanical Extracts', null),
    ('Cetyl Alc.', 'Cetyl Alcohol'), ('Panthenol (Pro Vitamin B5) Complex', 'Panthenol'),
    ('Rosmarinus Officinalis Leaf Extr.', 'Rosmarinus Officinalis Leaf Extract'), ('Hydrolysed Baobab Protein', null),
    ('Kakadu Plum Extract', 'Terminalia Ferdinandiana Fruit Extract'), ('Babchi Seed Extract', 'Psoralea Corylifolia Seed Extract'),
    ('Sodium Cocoyl Glycinate', null), ('Ceramide NG', null), ('Vitamin F', null), ('Bio-Retinol Complex', null),
    ('Sea Kelp Extract', 'Laminaria Digitata Extract'), ('Snail Secretion Filtrate', null), ('Probiotic Ferment', null),
    ('Lactobacillus Ferment Lysate', null), ('Hyaluronic Acid (Low Molecular Weight)', 'Hydrolyzed Hyaluronic Acid'),
    ('Aloe Leaf Juice Powder', 'Aloe Barbadensis Leaf Juice'), ('Sodium Hyaluronate Crosspolymer', null),
    ('Cocamidopropyl Betain', 'Cocamidopropyl Betaine'), ('Benzyl Alchol', 'Benzyl Alcohol'),
    ('Ethylhexylglycerine', 'Ethylhexylglycerin'), ('Shea Butter Extract', 'Butyrospermum Parkii Butter'),
    ('Green Tea', 'Camellia Sinensis Leaf Extract')
  ) as m (raw, resolves_to);

  insert into public.verification_queue
    (product_id, raw_name, normalized_name, reason, suggested_ingredient_id, similarity, source_id, source_url,
     status, resolved_ingredient_id, resolved_at, resolution_note, created_at)
  select p.id, m.raw, m.norm,
         case when m.suggested is not null then 'low_confidence'::public.queue_reason else 'unknown_ingredient' end,
         m.suggested, null, p.source_id, p.product_url,
         st.status,
         case when st.status = 'resolved' then coalesce(
           (select id from public.ingredients where normalized_name = public.normalize_inci(m.resolves_to)), m.suggested,
           (select id from public.ingredients order by id limit 1)) end,
         case when st.status <> 'pending' then st.created_at + interval '2 days' end,
         case when st.status = 'rejected' then 'not an INCI name' end,
         st.created_at
  from public.products p
  cross join lateral (select 1 + synthetic.h('mq:' || p.id, p_seed) % (select count(*) from tmp_messy) as k,
                             synthetic.h('ms:' || p.id, p_seed) % 100 as sh) r
  join tmp_messy m on m.k = r.k
  cross join lateral (select
      case when r.sh < 4 then 'pending'
           when r.sh < 40 then case when m.resolves_to is null and r.sh % 3 = 0 then 'rejected' else 'resolved' end
      end::public.queue_status as status,
      case when r.sh < 4 then now() - make_interval(hours => (synthetic.h('mt:' || p.id, p_seed) % 336)::int)
           else now() - make_interval(days => 15 + (synthetic.h('mt:' || p.id, p_seed) % 300)::int) end as created_at
  ) st
  where p.id > v_offset and st.status is not null;

  -- Repair drafts: pending proposals (swap two positions) and reviewed history
  insert into public.repair_drafts (product_id, proposed, provenance, source_id, reason, base_hash, status, created_via,
                                    created_at, reviewed_at, review_note)
  select p.id,
         (select jsonb_agg(jsonb_build_object(
                    'position', rn, 'ingredient_id', ingredient_id, 'inci_name', inci_name, 'raw_name', inci_name,
                    'confidence', case when d.prov = 'ai_suggested' then 0.82 end, 'source_url', null) order by rn)
            from (select pi.ingredient_id, i.inci_name,
                         row_number() over (order by case pi.position when 3 then 4 when 4 then 3 else pi.position end) as rn
                  from public.product_ingredients pi join public.ingredients i on i.id = pi.ingredient_id
                  where pi.product_id = p.id) s),
         d.prov, null, d.reason, p.ingredients_hash, d.status, d.via, d.created_at,
         case when d.status <> 'pending' then d.created_at + interval '1 day' end,
         case when d.status = 'rejected' then 'label photo confirms current order' when d.status = 'applied' then 'matches label' end
  from public.products p
  cross join lateral (select synthetic.h('d:' || p.id, p_seed) % 1000 as dh) r
  cross join lateral (select
      case when r.dh % 2 = 0 then 'ai_suggested' else 'manual' end::public.provenance_kind as prov,
      case when r.dh % 2 = 0 then 'AI reviewer: positions 3/4 look swapped vs. concentration'
           else 'Customer report: label order differs at positions 3-4' end as reason,
      case when r.dh < 6 then 'pending' when r.dh < 12 then 'rejected' else 'applied' end::public.draft_status as status,
      case when r.dh % 2 = 0 then 'ai' else 'admin' end as via,
      case when r.dh < 6 then now() - make_interval(hours => (r.dh * 13)::int) else now() - make_interval(days => 20 + (r.dh % 200)::int) end as created_at
  ) d
  where p.id > v_offset and r.dh < 20 and p.ingredient_count >= 5 and p.status = 'published';

  -- Audit history (synthetic, clearly marked) + one bulk-load record
  insert into public.audit_log (occurred_at, actor_kind, action, entity, entity_id, product_id, diff, context)
  select now() - make_interval(mins => (synthetic.h('al:' || p.id, p_seed) % 129600)::int),
         (array['service', 'admin', 'service', 'system'])[1 + (synthetic.h('ak:' || p.id, p_seed) % 4)::int],
         'repair_product_ingredients', 'product', p.id::text, p.id,
         jsonb_build_object('added', '[]'::jsonb, 'removed', '[]'::jsonb,
                            'moved', jsonb_build_array(jsonb_build_object('ingredient_id', 0, 'inci_name', 'synthetic history', 'from', 4, 'to', 3)),
                            'provenance', 'scraped', 'from_hash', md5(p.id || ':old'), 'to_hash', p.ingredients_hash),
         jsonb_build_object('reason', 'synthetic history', 'synthetic', true)
  from public.products p
  where p.id > v_offset and p.ingredients_hash is not null and synthetic.h('ah:' || p.id, p_seed) % 3 = 0;

  insert into public.audit_log (actor_kind, action, entity, entity_id, diff, context)
  values ('system', 'bulk_seed', 'catalog', null,
          jsonb_build_object('products', p_products, 'product_ingredients', v_rows),
          jsonb_build_object('seed', p_seed, 'generator', 'synthetic.generate_catalog'));

  analyze public.products;
  analyze public.product_ingredients;
  analyze public.analysis_cache;
  analyze public.verification_queue;
  analyze public.audit_log;

  return jsonb_build_object(
    'products', p_products, 'product_ingredients', v_rows,
    'ingredients', (select count(*) from public.ingredients),
    'aliases', (select count(*) from public.ingredient_aliases),
    'seconds', round(extract(epoch from clock_timestamp() - v_started)::numeric, 1));
end;
$$;

-- Hosted demo: keep a little work in the queues for visitors (scheduled daily on the demo project only).
create or replace function synthetic.top_up_demo(p_min_pending int default 40)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_pending int;
  v_added int := 0;
begin
  select count(*) into v_pending from public.verification_queue where status = 'pending';
  if v_pending < p_min_pending then
    insert into public.verification_queue (product_id, raw_name, normalized_name, reason, source_id, source_url)
    select p.id, m.raw, public.normalize_inci(m.raw), 'unknown_ingredient', p.source_id, p.product_url
    from (select id, source_id, product_url from public.products where status = 'published' order by random() limit p_min_pending) p
    cross join lateral (select (array['Glycerine (Vegetable)', 'Niacinamid', 'Kakadu Plum Extract', 'Essential Oil Blend',
                                      'Cetyl Alc.', 'Sea Kelp Extract', 'Benzyl Alchol', 'Ethylhexylglycerine'])[1 + floor(random() * 8)::int] as raw) m
    on conflict do nothing;
    get diagnostics v_added = row_count;
  end if;
  return jsonb_build_object('pending_before', v_pending, 'added', v_added);
end;
$$;
