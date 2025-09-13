// Lambda@Edge Bot Verification (Node.js 18+)
'use strict';

// Bot IP ranges - auto-updated by build process
// Run 'npm run update-ips' to fetch latest ranges
let BOT_IP_RANGES;
try {
  BOT_IP_RANGES = require('./bot-ip-ranges.js');
} catch {
  // Fallback ranges if external file not found
  BOT_IP_RANGES = {
    google: ['66.249.64.0/19', '64.233.160.0/19', '72.14.192.0/18', '208.65.144.0/20', '74.125.0.0/16'],
    bing: ['40.77.167.0/24', '157.55.39.0/24', '207.46.13.0/24', '65.52.104.0/24'],
    apple: ['17.0.0.0/8', '17.112.156.0/24'],
    facebook: ['31.13.24.0/21', '66.220.144.0/20', '69.63.176.0/20', '173.252.64.0/18'],
    linkedin: ['108.174.0.0/16', '144.2.0.0/16'],
    yandex: ['77.88.0.0/16', '87.250.224.0/19', '95.108.128.0/17'],
    baidu: ['180.76.0.0/16', '220.181.0.0/16']
  };
}

const BOT_ALLOW = [
  { ua: /Googlebot|Google-InspectionTool|AdsBot-Google/i, ipRanges: BOT_IP_RANGES.google, strictCheck: true },
  { ua: /Bingbot|BingPreview/i, ipRanges: BOT_IP_RANGES.bing, strictCheck: true },
  { ua: /Applebot/i, ipRanges: BOT_IP_RANGES.apple, strictCheck: true },
  { ua: /facebookexternalhit/i, ipRanges: BOT_IP_RANGES.facebook, strictCheck: true },
  { ua: /LinkedInBot/i, ipRanges: BOT_IP_RANGES.linkedin, strictCheck: true },
  { ua: /YandexBot/i, ipRanges: BOT_IP_RANGES.yandex, strictCheck: true },
  { ua: /Baiduspider/i, ipRanges: BOT_IP_RANGES.baidu, strictCheck: true },
  // Crawlers without published IP ranges (allow with less strict checking)
  { ua: /DuckDuckBot/i, strictCheck: false },
  { ua: /Slurp/i, strictCheck: false }, // Yahoo
  { ua: /Twitterbot/i, strictCheck: false },
  // AI crawlers (dynamic IPs, less strict checking)
  { ua: /GPTBot/i, strictCheck: false },
  { ua: /ClaudeBot/i, strictCheck: false },
  { ua: /PerplexityBot/i, strictCheck: false },
  { ua: /CCBot/i, strictCheck: false },
  { ua: /ChatGPT-User/i, strictCheck: false },
  // SEO tool crawlers (less strict due to varied IPs)
  { ua: /SemrushBot/i, strictCheck: false },
  { ua: /AhrefsBot/i, strictCheck: false },
  { ua: /MJ12bot/i, strictCheck: false },
  { ua: /DotBot/i, strictCheck: false }
];

function matchBotUA(ua) {
  if (!ua) return null;
  return BOT_ALLOW.find(b => b.ua.test(ua));
}

function getClientIP(headers, req) {
  const xff = headers['x-forwarded-for'] && headers['x-forwarded-for'][0] && headers['x-forwarded-for'][0].value;
  if (xff) {
    // Take the first IP, handle IPv6 brackets
    const ip = xff.split(',')[0].trim();
    return ip.startsWith('[') ? ip.slice(1, -1) : ip;
  }
  return req.clientIp || '';
}

function isValidIP(ip) {
  if (!ip) return false;
  // Basic IP validation (IPv4 and IPv6)
  const ipv4Regex = /^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/;
  const ipv6Regex = /^(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$|^::1$|^::$/;
  return ipv4Regex.test(ip) || ipv6Regex.test(ip);
}

function ipInRange(ip, cidr) {
  if (!cidr || !ip) return false;
  
  try {
    const [range, bits] = cidr.split('/');
    const mask = ~(2 ** (32 - parseInt(bits)) - 1);
    
    const ipNum = ip.split('.').reduce((num, octet) => (num << 8) + parseInt(octet), 0);
    const rangeNum = range.split('.').reduce((num, octet) => (num << 8) + parseInt(octet), 0);
    
    return (ipNum & mask) === (rangeNum & mask);
  } catch {
    return false;
  }
}

function verifyBotIP(ip, ipRanges) {
  if (!ip || !ipRanges || !Array.isArray(ipRanges)) return false;
  return ipRanges.some(range => ipInRange(ip, range));
}

function validateEvent(event) {
  try {
    return event && 
           event.Records && 
           event.Records[0] && 
           event.Records[0].cf && 
           event.Records[0].cf.request;
  } catch {
    return false;
  }
}

exports.handler = (event, context, callback) => {
  try {
    // Validate event structure
    if (!validateEvent(event)) {
      return callback(null, {
        status: '400',
        statusDescription: 'Bad Request',
        headers: {
          'content-type': [{ key: 'Content-Type', value: 'text/plain; charset=utf-8' }]
        },
        body: 'Invalid request structure'
      });
    }

    const req = event.Records[0].cf.request;
    const headers = req.headers || {};
    const ua = (headers['user-agent'] && headers['user-agent'][0] && headers['user-agent'][0].value) || '';
    const clientIp = getClientIP(headers, req);

    const bot = matchBotUA(ua);
    if (!bot) {
      // Not a known bot → let WAF/geo rules apply downstream
      return callback(null, req);
    }

    // Validate client IP
    if (!isValidIP(clientIp)) {
      // Invalid IP, likely spoofed → block
      return callback(null, {
        status: '403',
        statusDescription: 'Forbidden',
        headers: {
          'content-type': [{ key: 'Content-Type', value: 'text/plain; charset=utf-8' }],
          'cache-control': [{ key: 'Cache-Control', value: 'no-store' }]
        },
        body: 'Invalid request'
      });
    }

    // For bots with strict IP checking, verify against known IP ranges
    if (bot.strictCheck && bot.ipRanges) {
      if (!verifyBotIP(clientIp, bot.ipRanges)) {
        // IP not in known bot ranges → likely spoofed
        return callback(null, {
          status: '403',
          statusDescription: 'Forbidden', 
          headers: {
            'content-type': [{ key: 'Content-Type', value: 'text/plain; charset=utf-8' }],
            'cache-control': [{ key: 'Cache-Control', value: 'no-store' }]
          },
          body: 'Access denied'
        });
      }
    }

    // Bot verified → mark as verified and allow through
    req.headers['x-bot-verified'] = [{ key: 'X-Bot-Verified', value: 'true' }];
    req.headers['x-bot-type'] = [{ key: 'X-Bot-Type', value: bot.ua.source }];
    
    return callback(null, req);

  } catch (error) {
    // Handle any unexpected errors gracefully
    return callback(null, {
      status: '500',
      statusDescription: 'Internal Server Error',
      headers: {
        'content-type': [{ key: 'Content-Type', value: 'text/plain; charset=utf-8' }]
      },
      body: 'Service temporarily unavailable'
    });
  }
};