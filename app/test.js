const assert = require('assert');
const { page } = require('./index');

const html = page();
assert(html.includes('Palladium Platform'), 'title present');
assert(html.includes('ArgoCD'), 'ArgoCD reference present');
assert(html.includes('/health') === false, 'health endpoint not in page HTML');

console.log('tests passed');
process.exit(0);
