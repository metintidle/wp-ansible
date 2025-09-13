#!/usr/bin/env node
// update-bot-ips.js - Fetch latest bot IP ranges at build time

const https = require('https');
const fs = require('fs');
const dns = require('dns').promises;

// Known bot IP sources
const IP_SOURCES = {
  google: {
    url: 'https://www.gstatic.com/ipranges/goog.json',
    parser: (data) => {
      const json = JSON.parse(data);
      return json.prefixes
        .filter(p => p.ipv4Prefix && (p.service === 'Google' || p.service === 'Googlebot'))
        .map(p => p.ipv4Prefix);
    }
  },
  bing: {
    // Microsoft publishes via download center
    manual: [
      '40.77.167.0/24', '157.55.39.0/24', '207.46.13.0/24',
      '65.52.104.0/24', '65.55.213.0/24', '157.56.92.0/24'
    ]
  },
  // SPF records can reveal some IP ranges
  spf: {
    domains: ['_spf.google.com', 'spf.protection.outlook.com'],
    parser: async (domain) => {
      try {
        const records = await dns.resolveTxt(domain);
        const spfRecord = records.find(r => r[0].startsWith('v=spf1'));
        if (!spfRecord) return [];
        
        const includes = spfRecord[0].match(/include:([^\s]+)/g) || [];
        const ips = spfRecord[0].match(/ip4:([^\s]+)/g) || [];
        
        return ips.map(ip => ip.replace('ip4:', ''));
      } catch {
        return [];
      }
    }
  }
};

function fetchUrl(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => resolve(data));
      res.on('error', reject);
    });
  });
}

async function updateBotIPs() {
  console.log('🔄 Fetching latest bot IP ranges...');
  
  const updatedRanges = {};
  
  // Fetch Google IPs
  try {
    const googleData = await fetchUrl(IP_SOURCES.google.url);
    updatedRanges.google = IP_SOURCES.google.parser(googleData);
    console.log(`✅ Google: ${updatedRanges.google.length} ranges`);
  } catch (error) {
    console.warn('⚠️  Google IP fetch failed, using fallback');
    updatedRanges.google = [
      '66.249.64.0/19', '64.233.160.0/19', '72.14.192.0/18',
      '208.65.144.0/20', '74.125.0.0/16', '173.194.0.0/16'
    ];
  }
  
  // Use manual ranges for others (could be extended)
  updatedRanges.bing = IP_SOURCES.bing.manual;
  updatedRanges.apple = ['17.0.0.0/8', '17.112.156.0/24', '17.58.97.0/24'];
  
  // Generate updated JavaScript code
  const jsCode = `// Auto-generated bot IP ranges - ${new Date().toISOString()}
// Run 'node update-bot-ips.js' to refresh

const BOT_IP_RANGES = ${JSON.stringify(updatedRanges, null, 2)};

module.exports = BOT_IP_RANGES;
`;

  // Write to separate file
  fs.writeFileSync('./bot-ip-ranges.js', jsCode);
  console.log('✅ Updated bot-ip-ranges.js');
  
  return updatedRanges;
}

// Run if called directly
if (require.main === module) {
  updateBotIPs().catch(console.error);
}

module.exports = { updateBotIPs };