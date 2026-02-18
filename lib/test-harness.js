/**
 * Tritium Coder — Shared Test Harness
 *
 * Lightweight browser test framework for validating example projects.
 * Include via <script src="../../lib/test-harness.js"></script> in any
 * example's test.html.
 *
 * Usage:
 *   const t = new TritiumTest('My Game');
 *   t.test('loads without error', () => { ... });
 *   t.test('score starts at 0', () => t.assertEqual(score, 0));
 *   t.run();
 *
 * API:
 *   t.test(name, fn)          — register a test
 *   t.assertEqual(a, b)       — assert equality
 *   t.assertTrue(v)           — assert truthy
 *   t.assertFalse(v)          — assert falsy
 *   t.assertExists(sel)       — assert DOM element exists
 *   t.assertType(v, type)     — assert typeof
 *   t.assertThrows(fn)        — assert fn throws
 *   t.assertNoThrow(fn)       — assert fn does not throw
 *   t.run()                   — execute all tests, render results
 */

class TritiumTest {
  constructor(suiteName) {
    this.suiteName = suiteName || 'Tests';
    this.tests = [];
    this.results = [];
    this.passed = 0;
    this.failed = 0;
  }

  test(name, fn) {
    this.tests.push({ name, fn });
  }

  assertEqual(actual, expected, msg) {
    if (actual !== expected) {
      throw new Error(msg || `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    }
  }

  assertDeepEqual(actual, expected, msg) {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
      throw new Error(msg || `Deep equal failed:\n  Expected: ${JSON.stringify(expected)}\n  Got: ${JSON.stringify(actual)}`);
    }
  }

  assertTrue(value, msg) {
    if (!value) {
      throw new Error(msg || `Expected truthy, got ${JSON.stringify(value)}`);
    }
  }

  assertFalse(value, msg) {
    if (value) {
      throw new Error(msg || `Expected falsy, got ${JSON.stringify(value)}`);
    }
  }

  assertExists(selector, msg) {
    const el = document.querySelector(selector);
    if (!el) {
      throw new Error(msg || `Element not found: ${selector}`);
    }
    return el;
  }

  assertType(value, type, msg) {
    if (typeof value !== type) {
      throw new Error(msg || `Expected type ${type}, got ${typeof value}`);
    }
  }

  assertThrows(fn, msg) {
    let threw = false;
    try { fn(); } catch { threw = true; }
    if (!threw) {
      throw new Error(msg || 'Expected function to throw');
    }
  }

  assertNoThrow(fn, msg) {
    try {
      fn();
    } catch (e) {
      throw new Error(msg || `Expected no throw, but got: ${e.message}`);
    }
  }

  assertInRange(value, min, max, msg) {
    if (value < min || value > max) {
      throw new Error(msg || `Expected ${value} to be in range [${min}, ${max}]`);
    }
  }

  assertInstanceOf(value, cls, msg) {
    if (!(value instanceof cls)) {
      throw new Error(msg || `Expected instance of ${cls.name}`);
    }
  }

  async run() {
    this.passed = 0;
    this.failed = 0;
    this.results = [];

    for (const { name, fn } of this.tests) {
      try {
        const result = fn.call(this);
        if (result instanceof Promise) await result;
        this.results.push({ name, pass: true });
        this.passed++;
      } catch (e) {
        this.results.push({ name, pass: false, error: e.message || String(e) });
        this.failed++;
      }
    }

    this._render();
    return { passed: this.passed, failed: this.failed, total: this.tests.length };
  }

  _render() {
    // Create or find results container
    let container = document.getElementById('tritium-test-results');
    if (!container) {
      container = document.createElement('div');
      container.id = 'tritium-test-results';
      document.body.appendChild(container);
    }

    const allPass = this.failed === 0;

    container.innerHTML = `
      <style>
        #tritium-test-results {
          font-family: 'SF Mono', 'Fira Code', monospace;
          background: #0a0a0f;
          color: #e0e0e8;
          padding: 24px;
          margin: 20px;
          border-radius: 8px;
          border: 1px solid ${allPass ? '#4ade80' : '#f87171'};
          max-width: 700px;
        }
        .ttr-header {
          font-size: 18px;
          font-weight: 700;
          margin-bottom: 16px;
          color: ${allPass ? '#4ade80' : '#f87171'};
        }
        .ttr-summary {
          font-size: 14px;
          margin-bottom: 16px;
          padding: 8px 12px;
          border-radius: 4px;
          background: ${allPass ? '#1a3a1a' : '#3a1a1a'};
        }
        .ttr-test {
          padding: 6px 0;
          font-size: 13px;
          border-bottom: 1px solid #1a1a25;
          display: flex;
          align-items: flex-start;
          gap: 8px;
        }
        .ttr-test:last-child { border-bottom: none; }
        .ttr-pass { color: #4ade80; }
        .ttr-fail { color: #f87171; }
        .ttr-dot {
          width: 8px; height: 8px;
          border-radius: 50%;
          margin-top: 4px;
          flex-shrink: 0;
        }
        .ttr-dot.pass { background: #4ade80; }
        .ttr-dot.fail { background: #f87171; }
        .ttr-error {
          color: #f87171;
          font-size: 11px;
          margin-top: 2px;
          opacity: 0.8;
        }
        .ttr-name { flex: 1; }
      </style>
      <div class="ttr-header">${this.suiteName}</div>
      <div class="ttr-summary">
        ${allPass ? 'ALL PASS' : `${this.failed} FAILED`}
        &mdash; ${this.passed}/${this.tests.length} passed
      </div>
      ${this.results.map(r => `
        <div class="ttr-test">
          <div class="ttr-dot ${r.pass ? 'pass' : 'fail'}"></div>
          <div class="ttr-name">
            <span class="${r.pass ? 'ttr-pass' : 'ttr-fail'}">${r.pass ? 'PASS' : 'FAIL'}</span>
            ${r.name}
            ${r.error ? `<div class="ttr-error">${r.error}</div>` : ''}
          </div>
        </div>
      `).join('')}
    `;

    // Also log to console for headless/CI
    console.log(`\n${this.suiteName}: ${this.passed}/${this.tests.length} passed`);
    this.results.forEach(r => {
      if (r.pass) {
        console.log(`  ✓ ${r.name}`);
      } else {
        console.error(`  ✗ ${r.name}: ${r.error}`);
      }
    });
  }
}

// Export for both module and script contexts
if (typeof module !== 'undefined' && module.exports) {
  module.exports = TritiumTest;
}
if (typeof window !== 'undefined') {
  window.TritiumTest = TritiumTest;
}
