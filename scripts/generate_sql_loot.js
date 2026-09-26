const fs = require('fs');
const path = require('path');

const itemsPath = path.join(__dirname, 'admin-items.json');
const sqlPath = path.join(__dirname, '../setup_playtime_airdrops.sql');

if (!fs.existsSync(itemsPath)) {
  console.error("admin-items.json not found!");
  process.exit(1);
}

const rawData = fs.readFileSync(itemsPath, 'utf8');
const items = JSON.parse(rawData);

const gameItems = { tiers: {} };
for (let t = 0; t <= 6; t++) {
  gameItems.tiers[t] = { resources: [], gear: [], schematics: [] };
}

function getTier(item) {
  const id = item.id.toLowerCase();
  const name = item.name.toLowerCase();

  if (item.category === 'resources') {
    if (id.startsWith('t6') || id.includes('plastanium') || id.includes('chemicalreagent_t1') || id === 'silicone' || id === 'melangespice' || id === 'fremencomponent2' || id.startsWith('oldimperialcomponent') || id.startsWith('greathousecomponent') || id.includes('wormtooth') || id.includes('landsraad') || id === 'spicedfuelcell' || id === 'shigawiregarotte') return 6;
    if (id.startsWith('t5') || id.includes('duraluminum') || id.includes('duraluminium') || id === 'fremencomponent1' || id.includes('cobalt')) return 5;
    if (id.startsWith('t4') || id.includes('aluminum') || id.includes('aluminium') || id.includes('erythrite') || id === 'bauxiteore' || id === 'plastone') return 4;
    if (id.startsWith('t3') || id.includes('steel') || id.includes('jasmium')) return 3;
    if (id.startsWith('t2') || id.includes('iron') || id.includes('plasteel') || id.includes('dolomite') || id.includes('saguaro') || id === 'magnetiteore') return 2;
    if (id.startsWith('t1') || id.includes('copper') || id.includes('floursand') || id.includes('basalt') || id === 'azuriteore') return 1;
    if (id.includes('scrap')) return 0;
  }

  if (id.includes('regis')) return 6;
  if (id.includes('adept')) return 5;
  if (id.includes('duneman')) return 3;
  if (id.includes('kirabstillsuit')) return 2;
  if (id.includes('kirab')) return 1;
  if (id.includes('slaverstillsuit')) return 3;
  if (id.includes('slaver')) return 2;
  if (id.includes('mercenarystillsuit')) return 5;
  if (id.includes('mercenary')) return 4;
  if (id.includes('choamstillsuit')) return 6;
  if (id.includes('choam')) return 5;

  if (id.includes('scrap') || id.includes('makeshift')) return 0;

  for (let t = 1; t <= 6; t++) {
    if (id.startsWith(`t${t}`) || id.includes(`_t${t}_`) || id.includes(`t${t}_`) || id.includes(`_t${t}`) || id.includes(`_0${t}_`) || id.endsWith(`_0${t}`) || id.includes(`t${t}schematic`)) {
      return t;
    }
  }

  if (name.includes('mk6')) return 6;
  if (name.includes('mk5')) return 5;
  if (name.includes('mk4')) return 4;
  if (name.includes('mk3')) return 3;
  if (name.includes('mk2')) return 2;
  if (name.includes('mk1')) return 1;

  return 0;
}

function getTiersForResource(item) {
  const id = item.id.toLowerCase();
  
  if (id === 'plantfiber' || id === 'stone' || id === 'solariscoin') return [0, 1, 2, 3, 4, 5, 6];
  if (id === 'silicone' || id === 'dolomiterock' || id === 'floursand' || id === 'basalt' || id === 'oldimperialcomponent1' || id === 'oldimperialcomponent2' || id === 'greathousecomponent1' || id === 'greathousecomponent2') return [1, 2, 3, 4, 5, 6];
  
  if (id === 'erythritecrystal') return [3, 4, 5, 6];
  if (id === 't3vendorcomponent1' || id === 'saguaroresourceraw') return [3, 4, 5, 6];
  if (id === 'spicesand' || id === 'spiceresidue') return [5, 6];
  if (id === 'melangespice') return [6];
  
  if (id === 'scrapmetal') return [0, 1, 2, 3];
  if (id === 'weldingmaterial') return [1, 2, 3];
  if (id === 'weldingmaterial3') return [3, 4, 5];
  if (id === 'weldingmaterial5') return [5, 6];
  
  if (id === 'fuelcanister') return [1, 2];
  if (id === 'fuelcanister_medium') return [2, 3, 4];
  if (id === 'fuelcanister_large') return [5, 6];

  if (id === 'windturbinelubricant1') return [2, 3, 4];
  if (id === 'windturbinelubricant2') return [4, 5, 6];
  
  if (id === 'windtrapfilter1') return [1, 2];
  if (id === 'windtrapfilter2') return [3, 4];
  if (id === 'windtrapfilter3') return [4, 5];
  if (id === 'windtrapfilter4') return [5, 6];

  const excluded = [
    't2muaddibcomponent', 'wormtooth', 'shigawiregarotte', 'corpse', 
    'blanksinkchart', 'missionariaprotectivadoc3', 'experimentalwindturbinecomponent', 
    'eventraidertoken', 'eventeliteraidertoken'
  ];
  if (excluded.includes(id)) {
    return [];
  }

  return [getTier(item)];
}

function getResourceWeight(id, tier) {
  const idL = id.toLowerCase();
  
  // Exclude extremely common generic map resources from taking over high-tier loot tables
  if (idL === 'stone' || idL === 'plantfiber') {
    if (tier >= 4) return 0; // Exclude entirely at high tiers
    return Math.max(10, 100 - (tier * 25));
  }
  
  if (idL === 'scrapmetal') return Math.max(10, 100 - (tier * 25));
  if (idL === 'ironore' && tier >= 4) return 10;
  if (idL === 'copperore' && tier >= 3) return 10;
  if (idL === 'azuriteore') return 20;

  if (idL === 'solariscoin') return 10; // Keep coins rare

  // T1-T2 basics taper down
  if ((idL.includes('weldingmaterial') || idL.includes('fuelcanister') || idL.includes('windtrapfilter')) && tier >= 4) {
    return 20;
  }

  // Weight highly sought-after intermediate components up slightly
  if (idL.includes('oldimperialcomponent') || idL.includes('greathousecomponent')) {
    return 30; // Still keep rare, but standard rate
  }

  // Make T6 exclusive materials common if rolled in T6
  if (tier === 6 && (idL.includes('t6') || idL.includes('plastanium'))) {
    return 150;
  }

  if (idL.includes('melangespice')) return 5; // Very rare

  return 100; // Default weight
}

items.forEach(item => {
  const tier = getTier(item);
  const cat = item.category;
  
  if (cat === 'resources') {
    const idLower = item.id.toLowerCase();
    if (idLower.includes('fragment') || idLower.includes('pattern')) {
      if (tier === 6 && (idLower.includes('ql4') || idLower.includes('ql5'))) {
        gameItems.tiers[6].resources.push(item);
      }
      return; 
    }
    
    const tiers = getTiersForResource(item);
    tiers.forEach(t => {
      gameItems.tiers[t].resources.push(item);
    });
  } else if (cat === 'schematics') {
    const idLower = item.id.toLowerCase();
    if (idLower.includes('dummy') || idLower.includes('placeholder') || idLower.includes('test') || idLower.includes('npe_') || idLower.includes('fragment')) {
      return;
    }
    gameItems.tiers[tier].schematics.push(item);
  } else if (['clothing', 'weapons', 'vehicles'].includes(cat)) {
    const idLower = item.id.toLowerCase();
    if (idLower.includes('augment')) {
      return;
    }
    gameItems.tiers[tier].gear.push(item);
  }
});

let sqlOutput = `-- ==========================================
-- AUTO-GENERATED BY generate_sql_loot.js
-- DO NOT EDIT THIS BLOCK MANUALLY
-- ==========================================\n\n`;

// The table is created by the main script; the pool is replaced wholesale so
// a regenerated item list never leaves stale rows behind.
sqlOutput += `TRUNCATE dune_airdrop.airdrop_loot_table;

`;

sqlOutput += `INSERT INTO dune_airdrop.airdrop_loot_table (tier, category, template_id, weight) VALUES\n`;

const valuesList = [];

function getResourceSubcategory(id) {
  const rawKeywords = ['ore', 'stone', 'sand', 'fiber', 'wood', 'water', 'raw', 'residue', 'spice', 'plant'];
  if (rawKeywords.some(kw => id.toLowerCase().includes(kw))) return 'raw_resources';
  return 'crafted_components';
}

for (let t = 0; t <= 6; t++) {
  // Resources
  gameItems.tiers[t].resources.forEach(r => {
    const weight = getResourceWeight(r.id, t);
    if (weight > 0) {
      const subcat = getResourceSubcategory(r.id);
      valuesList.push(`(${t}, '${subcat}', '${r.id}', ${weight})`);
    }
  });

  // Gear
  gameItems.tiers[t].gear.forEach(g => {
    valuesList.push(`(${t}, 'gear', '${g.id}', 100)`);
  });

  // Schematics
  gameItems.tiers[t].schematics.forEach(s => {
    valuesList.push(`(${t}, 'schematics', '${s.id}', 100)`);
  });
}

// Add fallback values in case something breaks
if (valuesList.length === 0) {
  valuesList.push(`(0, 'raw_resources', 'ScrapMetal', 100)`);
}

sqlOutput += valuesList.join(',\n') + '\nON CONFLICT (tier, category, template_id) DO NOTHING;\n\n';
sqlOutput += `-- ==========================================`;

// Read the SQL file, replace the section between markers
const sqlContent = fs.readFileSync(sqlPath, 'utf8');
const startMarker = '-- \\[BEGIN AUTO-GENERATED LOOT POOLS\\]';
const endMarker = '-- \\[END AUTO-GENERATED LOOT POOLS\\]';

const regex = new RegExp(`${startMarker}[\\s\\S]*?${endMarker}`);
const newSqlContent = sqlContent.replace(regex, `-- [BEGIN AUTO-GENERATED LOOT POOLS]\n${sqlOutput}\n-- [END AUTO-GENERATED LOOT POOLS]`);
fs.writeFileSync(sqlPath, newSqlContent);
console.log('setup_playtime_airdrops.sql updated successfully.');

