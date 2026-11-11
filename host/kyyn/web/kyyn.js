(function () {
  'use strict';
  const views = __KYYN_VIEWS__;
  const context = __KYYN_CONTEXT__;
  window.kyyn = Object.freeze({
    async query(name, args) {
      const response = await fetch('/kb/queries/' + encodeURIComponent(name), {
        method: 'POST', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(args === undefined ? {} : args), cache: 'no-store'
      });
      const envelope = await response.json();
      if (!response.ok || envelope.outcome !== 'Succeeded') {
        const error = new Error((envelope.diagnostics || []).map(d => d.message).join('\n') || 'Query failed');
        Object.assign(error, {status: response.status, outcome: envelope.outcome,
          diagnostics: envelope.diagnostics || [], context: envelope.context});
        throw error;
      }
      return envelope.result;
    },
    viewUrl(name, params) {
      if (!views.includes(name)) throw new Error('Undeclared view: ' + name);
      const query = new URLSearchParams(params).toString();
      return '/kb/views/' + encodeURIComponent(name) + '/' + (query ? '?' + query : '');
    },
    params() { return new URLSearchParams(window.location.search); }
  });
  // Context is available for diagnostics without changing authored page markup.
  void context;
}());
