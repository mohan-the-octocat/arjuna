import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DATA_DIR = path.join(__dirname, 'data');
const RAW_DIR = path.join(DATA_DIR, 'admin_raw');
const CONFIG_PATH = path.join(__dirname, 'admin_config.json');
const OUT_PATH = path.join(DATA_DIR, 'admin.json');

function num(v) {
  if (v === null || v === undefined || v === '') return 0;
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function safeDiv(n, d, scale = 1, digits = 4) {
  const numVal = Number(n);
  const denVal = Number(d);
  if (!Number.isFinite(numVal) || !Number.isFinite(denVal) || denVal === 0) return null;
  const factor = Math.pow(10, digits);
  return Math.round((numVal / denVal) * scale * factor) / factor;
}

function round(v, digits = 2) {
  if (v === null || v === undefined || !Number.isFinite(Number(v))) return null;
  const factor = Math.pow(10, digits);
  return Math.round(Number(v) * factor) / factor;
}

function addDays(dateStr, deltaDays) {
  const d = new Date(`${dateStr}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + deltaDays);
  return d.toISOString().slice(0, 10);
}

function getMonday(dateStr) {
  const d = new Date(`${dateStr.slice(0, 10)}T00:00:00Z`);
  const day = d.getUTCDay();
  const diff = day === 0 ? -6 : 1 - day;
  d.setUTCDate(d.getUTCDate() + diff);
  return d.toISOString().slice(0, 10);
}

function parseTsMs(tsStr) {
  if (!tsStr) return null;
  const normalized = String(tsStr).trim().replace(' ', 'T').replace(/ UTC$/, 'Z');
  const withTz = normalized.endsWith('Z') || /[+-]\d{2}:\d{2}$/.test(normalized) ? normalized : `${normalized}Z`;
  const ms = Date.parse(withTz);
  return Number.isFinite(ms) ? ms : null;
}

function tsToDateStr(tsStr) {
  if (!tsStr) return '';
  const ms = parseTsMs(tsStr);
  if (ms !== null) return new Date(ms).toISOString().slice(0, 10);
  return String(tsStr).slice(0, 10);
}

function versionKey(ver) {
  return String(ver || '0')
    .split('.')
    .map(p => {
      const n = parseInt(p, 10);
      return Number.isFinite(n) ? n : 0;
    });
}

function compareVersions(a, b) {
  const ka = versionKey(a);
  const kb = versionKey(b);
  const len = Math.max(ka.length, kb.length);
  for (let i = 0; i < len; i++) {
    const diff = (ka[i] || 0) - (kb[i] || 0);
    if (diff !== 0) return diff;
  }
  return String(a).localeCompare(String(b));
}

function readJson(filePath, fallback = []) {
  if (!fs.existsSync(filePath)) return fallback;
  const raw = fs.readFileSync(filePath, 'utf8').trim();
  if (!raw) return fallback;
  return JSON.parse(raw);
}

function validateContract(admin) {
  const errors = [];
  const reqObj = (obj, key, ctx) => {
    if (!obj || typeof obj !== 'object' || !(key in obj)) {
      errors.push(`Missing key ${ctx}.${key}`);
      return undefined;
    }
    return obj[key];
  };
  const assertType = (val, type, ctx, allowNull = false) => {
    if (val === null && allowNull) return;
    if (type === 'array') {
      if (!Array.isArray(val)) errors.push(`${ctx} must be array, got ${typeof val}`);
      return;
    }
    if (type === 'number') {
      if (typeof val !== 'number' || !Number.isFinite(val)) {
        errors.push(`${ctx} must be finite number${allowNull ? '|null' : ''}, got ${val}`);
      }
      return;
    }
    if (type === 'object') {
      if (val === null || typeof val !== 'object' || Array.isArray(val)) {
        errors.push(`${ctx} must be object, got ${val}`);
      }
      return;
    }
    if (typeof val !== type) {
      errors.push(`${ctx} must be ${type}${allowNull ? '|null' : ''}, got ${typeof val}`);
    }
  };

  assertType(admin, 'object', 'root');
  if (errors.length) return errors;

  const cfg = reqObj(admin, 'config', 'root');
  assertType(cfg, 'object', 'config');
  if (cfg) {
    assertType(reqObj(cfg, 'window_days', 'config'), 'number', 'config.window_days');
    assertType(reqObj(cfg, 'corporate_domains', 'config'), 'array', 'config.corporate_domains');
    assertType(reqObj(cfg, 'project_budgets_usd', 'config'), 'object', 'config.project_budgets_usd');
    assertType(reqObj(cfg, 'budget_alert_thresholds', 'config'), 'array', 'config.budget_alert_thresholds');
    assertType(reqObj(cfg, 'fast_approval_seconds', 'config'), 'number', 'config.fast_approval_seconds');
    assertType(reqObj(cfg, 'abandon_idle_hours', 'config'), 'number', 'config.abandon_idle_hours');
    assertType(reqObj(cfg, 'rightsizing_max_steps', 'config'), 'number', 'config.rightsizing_max_steps');
    assertType(reqObj(cfg, 'runaway_min_steps', 'config'), 'number', 'config.runaway_min_steps');
  }

  const win = reqObj(admin, 'window', 'root');
  assertType(win, 'object', 'window');
  if (win) {
    assertType(reqObj(win, 'start', 'window'), 'string', 'window.start');
    assertType(reqObj(win, 'end', 'window'), 'string', 'window.end');
    assertType(reqObj(win, 'days', 'window'), 'number', 'window.days');
  }

  const rc = reqObj(admin, 'rate_card', 'root');
  assertType(rc, 'array', 'rate_card');
  if (Array.isArray(rc)) {
    rc.forEach((r, i) => {
      assertType(reqObj(r, 'model', `rate_card[${i}]`), 'string', `rate_card[${i}].model`);
      assertType(reqObj(r, 'usd_per_1m_tokens', `rate_card[${i}]`), 'number', `rate_card[${i}].usd_per_1m_tokens`);
      assertType(reqObj(r, 'source', `rate_card[${i}]`), 'string', `rate_card[${i}].source`);
    });
  }

  const ov = reqObj(admin, 'overview', 'root');
  assertType(ov, 'object', 'overview');
  if (ov) {
    assertType(reqObj(ov, 'wau', 'overview'), 'number', 'overview.wau');
    assertType(reqObj(ov, 'wau_prev', 'overview'), 'number', 'overview.wau_prev');
    assertType(reqObj(ov, 'cost_per_resolved_usd', 'overview'), 'number', 'overview.cost_per_resolved_usd', true);
    assertType(reqObj(ov, 'cost_per_resolved_usd_prev', 'overview'), 'number', 'overview.cost_per_resolved_usd_prev', true);
    assertType(reqObj(ov, 'rework_rate', 'overview'), 'number', 'overview.rework_rate', true);
    assertType(reqObj(ov, 'rework_rate_prev', 'overview'), 'number', 'overview.rework_rate_prev', true);
    assertType(reqObj(ov, 'privacy_checks_passing', 'overview'), 'number', 'overview.privacy_checks_passing');
    assertType(reqObj(ov, 'privacy_checks_total', 'overview'), 'number', 'overview.privacy_checks_total');
    assertType(reqObj(ov, 'current_version', 'overview'), 'string', 'overview.current_version', true);
    assertType(reqObj(ov, 'fleet_on_current_version_pct', 'overview'), 'number', 'overview.fleet_on_current_version_pct', true);
  }

  const alerts = reqObj(admin, 'alerts', 'root');
  assertType(alerts, 'array', 'alerts');
  if (Array.isArray(alerts)) {
    alerts.forEach((a, i) => {
      assertType(reqObj(a, 'severity', `alerts[${i}]`), 'string', `alerts[${i}].severity`);
      assertType(reqObj(a, 'theme', `alerts[${i}]`), 'string', `alerts[${i}].theme`);
      assertType(reqObj(a, 'title', `alerts[${i}]`), 'string', `alerts[${i}].title`);
      assertType(reqObj(a, 'detail', `alerts[${i}]`), 'string', `alerts[${i}].detail`);
    });
  }

  const val = reqObj(admin, 'value', 'root');
  assertType(val, 'object', 'value');
  if (val) {
    const pom = reqObj(val, 'proposal_outcomes_by_model', 'value');
    assertType(pom, 'array', 'value.proposal_outcomes_by_model');
    if (Array.isArray(pom)) {
      pom.forEach((r, i) => {
        assertType(reqObj(r, 'model', `pom[${i}]`), 'string', `pom[${i}].model`);
        assertType(reqObj(r, 'experience', `pom[${i}]`), 'string', `pom[${i}].experience`);
        assertType(reqObj(r, 'accepted', `pom[${i}]`), 'number', `pom[${i}].accepted`);
        assertType(reqObj(r, 'modified', `pom[${i}]`), 'number', `pom[${i}].modified`);
        assertType(reqObj(r, 'rejected', `pom[${i}]`), 'number', `pom[${i}].rejected`);
        assertType(reqObj(r, 'total', `pom[${i}]`), 'number', `pom[${i}].total`);
        assertType(reqObj(r, 'rework_rate', `pom[${i}]`), 'number', `pom[${i}].rework_rate`, true);
      });
    }
    const pow = reqObj(val, 'proposal_outcomes_weekly', 'value');
    assertType(pow, 'array', 'value.proposal_outcomes_weekly');
    if (Array.isArray(pow)) {
      pow.forEach((r, i) => {
        assertType(reqObj(r, 'week_start', `pow[${i}]`), 'string', `pow[${i}].week_start`);
        assertType(reqObj(r, 'accepted', `pow[${i}]`), 'number', `pow[${i}].accepted`);
        assertType(reqObj(r, 'modified', `pow[${i}]`), 'number', `pow[${i}].modified`);
        assertType(reqObj(r, 'rejected', `pow[${i}]`), 'number', `pow[${i}].rejected`);
        assertType(reqObj(r, 'rework_rate', `pow[${i}]`), 'number', `pow[${i}].rework_rate`, true);
      });
    }
    const os = reqObj(val, 'outcomes_summary', 'value');
    assertType(os, 'object', 'value.outcomes_summary');
    if (os) {
      assertType(reqObj(os, 'trajectories', 'outcomes_summary'), 'number', 'outcomes_summary.trajectories');
      assertType(reqObj(os, 'resolved', 'outcomes_summary'), 'number', 'outcomes_summary.resolved');
      assertType(reqObj(os, 'abandoned', 'outcomes_summary'), 'number', 'outcomes_summary.abandoned');
      assertType(reqObj(os, 'in_flight', 'outcomes_summary'), 'number', 'outcomes_summary.in_flight');
      assertType(reqObj(os, 'est_cost_usd', 'outcomes_summary'), 'number', 'outcomes_summary.est_cost_usd');
      assertType(reqObj(os, 'resolved_cost_usd', 'outcomes_summary'), 'number', 'outcomes_summary.resolved_cost_usd');
      assertType(reqObj(os, 'abandoned_cost_usd', 'outcomes_summary'), 'number', 'outcomes_summary.abandoned_cost_usd');
      assertType(reqObj(os, 'cost_per_resolved_usd', 'outcomes_summary'), 'number', 'outcomes_summary.cost_per_resolved_usd', true);
      assertType(reqObj(os, 'abandoned_cost_pct', 'outcomes_summary'), 'number', 'outcomes_summary.abandoned_cost_pct', true);
    }
    const omt = reqObj(val, 'outcomes_by_model_tier', 'value');
    assertType(omt, 'array', 'value.outcomes_by_model_tier');
    if (Array.isArray(omt)) {
      omt.forEach((r, i) => {
        assertType(reqObj(r, 'model', `omt[${i}]`), 'string', `omt[${i}].model`);
        assertType(reqObj(r, 'experience', `omt[${i}]`), 'string', `omt[${i}].experience`);
        assertType(reqObj(r, 'trajectories', `omt[${i}]`), 'number', `omt[${i}].trajectories`);
        assertType(reqObj(r, 'resolved', `omt[${i}]`), 'number', `omt[${i}].resolved`);
        assertType(reqObj(r, 'resolution_rate', `omt[${i}]`), 'number', `omt[${i}].resolution_rate`, true);
        assertType(reqObj(r, 'est_cost_usd', `omt[${i}]`), 'number', `omt[${i}].est_cost_usd`);
        assertType(reqObj(r, 'cost_per_resolved_usd', `omt[${i}]`), 'number', `omt[${i}].cost_per_resolved_usd`, true);
        assertType(reqObj(r, 'abandoned_cost_usd', `omt[${i}]`), 'number', `omt[${i}].abandoned_cost_usd`);
      });
    }
  }

  const cost = reqObj(admin, 'cost', 'root');
  assertType(cost, 'object', 'cost');
  if (cost) {
    const ps = reqObj(cost, 'project_showback', 'cost');
    assertType(ps, 'array', 'cost.project_showback');
    if (Array.isArray(ps)) {
      ps.forEach((r, i) => {
        assertType(reqObj(r, 'project_id', `ps[${i}]`), 'string', `ps[${i}].project_id`);
        assertType(reqObj(r, 'project_number', `ps[${i}]`), 'string', `ps[${i}].project_number`);
        assertType(reqObj(r, 'users', `ps[${i}]`), 'number', `ps[${i}].users`);
        assertType(reqObj(r, 'trajectories', `ps[${i}]`), 'number', `ps[${i}].trajectories`);
        assertType(reqObj(r, 'inferences', `ps[${i}]`), 'number', `ps[${i}].inferences`);
        assertType(reqObj(r, 'total_tokens', `ps[${i}]`), 'number', `ps[${i}].total_tokens`);
        assertType(reqObj(r, 'est_cost_usd', `ps[${i}]`), 'number', `ps[${i}].est_cost_usd`);
        assertType(reqObj(r, 'budget_usd', `ps[${i}]`), 'number', `ps[${i}].budget_usd`, true);
        assertType(reqObj(r, 'budget_pct', `ps[${i}]`), 'number', `ps[${i}].budget_pct`, true);
        assertType(reqObj(r, 'status', `ps[${i}]`), 'string', `ps[${i}].status`);
      });
    }
    const pd = reqObj(cost, 'project_daily', 'cost');
    assertType(pd, 'array', 'cost.project_daily');
    if (Array.isArray(pd)) {
      pd.forEach((r, i) => {
        assertType(reqObj(r, 'event_date', `pd[${i}]`), 'string', `pd[${i}].event_date`);
        assertType(reqObj(r, 'project_id', `pd[${i}]`), 'string', `pd[${i}].project_id`);
        assertType(reqObj(r, 'est_cost_usd', `pd[${i}]`), 'number', `pd[${i}].est_cost_usd`);
      });
    }
    const aov = reqObj(cost, 'aux_overhead_by_version', 'cost');
    assertType(aov, 'array', 'cost.aux_overhead_by_version');
    if (Array.isArray(aov)) {
      aov.forEach((r, i) => {
        assertType(reqObj(r, 'client_name', `aov[${i}]`), 'string', `aov[${i}].client_name`);
        assertType(reqObj(r, 'client_version', `aov[${i}]`), 'string', `aov[${i}].client_version`);
        assertType(reqObj(r, 'total_calls', `aov[${i}]`), 'number', `aov[${i}].total_calls`);
        assertType(reqObj(r, 'aux_calls', `aov[${i}]`), 'number', `aov[${i}].aux_calls`);
        assertType(reqObj(r, 'aux_call_pct', `aov[${i}]`), 'number', `aov[${i}].aux_call_pct`, true);
        assertType(reqObj(r, 'total_tokens', `aov[${i}]`), 'number', `aov[${i}].total_tokens`);
        assertType(reqObj(r, 'aux_tokens', `aov[${i}]`), 'number', `aov[${i}].aux_tokens`);
        assertType(reqObj(r, 'aux_token_pct', `aov[${i}]`), 'number', `aov[${i}].aux_token_pct`, true);
        assertType(reqObj(r, 'first_seen', `aov[${i}]`), 'string', `aov[${i}].first_seen`);
      });
    }
    const aow = reqObj(cost, 'aux_overhead_weekly', 'cost');
    assertType(aow, 'array', 'cost.aux_overhead_weekly');
    if (Array.isArray(aow)) {
      aow.forEach((r, i) => {
        assertType(reqObj(r, 'week_start', `aow[${i}]`), 'string', `aow[${i}].week_start`);
        assertType(reqObj(r, 'aux_token_pct', `aow[${i}]`), 'number', `aow[${i}].aux_token_pct`, true);
      });
    }
    const avs = reqObj(cost, 'automation_vs_seat_weekly', 'cost');
    assertType(avs, 'array', 'cost.automation_vs_seat_weekly');
    if (Array.isArray(avs)) {
      avs.forEach((r, i) => {
        assertType(reqObj(r, 'week_start', `avs[${i}]`), 'string', `avs[${i}].week_start`);
        assertType(reqObj(r, 'subscription_tier_type', `avs[${i}]`), 'string', `avs[${i}].subscription_tier_type`);
        assertType(reqObj(r, 'total_tokens', `avs[${i}]`), 'number', `avs[${i}].total_tokens`);
      });
    }
    const rz = reqObj(cost, 'rightsizing', 'cost');
    assertType(rz, 'array', 'cost.rightsizing');
    if (Array.isArray(rz)) {
      rz.forEach((r, i) => {
        assertType(reqObj(r, 'project_id', `rz[${i}]`), 'string', `rz[${i}].project_id`);
        assertType(reqObj(r, 'experience', `rz[${i}]`), 'string', `rz[${i}].experience`);
        assertType(reqObj(r, 'trajectories', `rz[${i}]`), 'number', `rz[${i}].trajectories`);
        assertType(reqObj(r, 'short_trajectories', `rz[${i}]`), 'number', `rz[${i}].short_trajectories`);
        assertType(reqObj(r, 'short_pct', `rz[${i}]`), 'number', `rz[${i}].short_pct`, true);
        assertType(reqObj(r, 'est_cost_usd', `rz[${i}]`), 'number', `rz[${i}].est_cost_usd`);
        assertType(reqObj(r, 'short_cost_usd', `rz[${i}]`), 'number', `rz[${i}].short_cost_usd`);
        assertType(reqObj(r, 'resolution_rate', `rz[${i}]`), 'number', `rz[${i}].resolution_rate`, true);
      });
    }
    const rs = reqObj(cost, 'runaway_sessions', 'cost');
    assertType(rs, 'array', 'cost.runaway_sessions');
    if (Array.isArray(rs)) {
      rs.forEach((r, i) => {
        assertType(reqObj(r, 'trajectory_id', `rs[${i}]`), 'string', `rs[${i}].trajectory_id`);
        assertType(reqObj(r, 'project_id', `rs[${i}]`), 'string', `rs[${i}].project_id`);
        assertType(reqObj(r, 'user_email', `rs[${i}]`), 'string', `rs[${i}].user_email`);
        assertType(reqObj(r, 'steps', `rs[${i}]`), 'number', `rs[${i}].steps`);
        assertType(reqObj(r, 'total_tokens', `rs[${i}]`), 'number', `rs[${i}].total_tokens`);
        assertType(reqObj(r, 'est_cost_usd', `rs[${i}]`), 'number', `rs[${i}].est_cost_usd`);
        assertType(reqObj(r, 'first_ts', `rs[${i}]`), 'string', `rs[${i}].first_ts`);
        assertType(reqObj(r, 'last_ts', `rs[${i}]`), 'string', `rs[${i}].last_ts`);
        assertType(reqObj(r, 'resolved', `rs[${i}]`), 'boolean', `rs[${i}].resolved`);
      });
    }
  }

  const sec = reqObj(admin, 'security', 'root');
  assertType(sec, 'object', 'security');
  if (sec) {
    const pc = reqObj(sec, 'privacy_checks', 'security');
    assertType(pc, 'array', 'security.privacy_checks');
    if (Array.isArray(pc)) {
      pc.forEach((r, i) => {
        assertType(reqObj(r, 'id', `pc[${i}]`), 'string', `pc[${i}].id`);
        assertType(reqObj(r, 'label', `pc[${i}]`), 'string', `pc[${i}].label`);
        assertType(reqObj(r, 'status', `pc[${i}]`), 'string', `pc[${i}].status`);
        assertType(reqObj(r, 'detail', `pc[${i}]`), 'string', `pc[${i}].detail`);
      });
    }
    const pf = reqObj(sec, 'privacy_facts', 'security');
    assertType(pf, 'object', 'security.privacy_facts');
    if (pf) {
      assertType(reqObj(pf, 'requests_total', 'privacy_facts'), 'number', 'privacy_facts.requests_total');
      assertType(reqObj(pf, 'requests_with_prompt_text', 'privacy_facts'), 'number', 'privacy_facts.requests_with_prompt_text');
      assertType(reqObj(pf, 'responses_total', 'privacy_facts'), 'number', 'privacy_facts.responses_total');
      assertType(reqObj(pf, 'responses_with_candidates', 'privacy_facts'), 'number', 'privacy_facts.responses_with_candidates');
      assertType(reqObj(pf, 'oldest_request_ts', 'privacy_facts'), 'string', 'privacy_facts.oldest_request_ts', true);
      assertType(reqObj(pf, 'partition_expiration_days', 'privacy_facts'), 'number', 'privacy_facts.partition_expiration_days', true);
      assertType(reqObj(pf, 'distinct_user_emails', 'privacy_facts'), 'number', 'privacy_facts.distinct_user_emails');
    }
    const idm = reqObj(sec, 'identity_domains', 'security');
    assertType(idm, 'array', 'security.identity_domains');
    if (Array.isArray(idm)) {
      idm.forEach((r, i) => {
        assertType(reqObj(r, 'domain', `idm[${i}]`), 'string', `idm[${i}].domain`);
        assertType(reqObj(r, 'users', `idm[${i}]`), 'number', `idm[${i}].users`);
        assertType(reqObj(r, 'projects', `idm[${i}]`), 'number', `idm[${i}].projects`);
        assertType(reqObj(r, 'inferences', `idm[${i}]`), 'number', `idm[${i}].inferences`);
        assertType(reqObj(r, 'is_corporate', `idm[${i}]`), 'boolean', `idm[${i}].is_corporate`);
        assertType(reqObj(r, 'first_seen', `idm[${i}]`), 'string', `idm[${i}].first_seen`);
        assertType(reqObj(r, 'last_seen', `idm[${i}]`), 'string', `idm[${i}].last_seen`);
      });
    }
    const app = reqObj(sec, 'approval_posture_by_project', 'security');
    assertType(app, 'array', 'security.approval_posture_by_project');
    if (Array.isArray(app)) {
      app.forEach((r, i) => {
        assertType(reqObj(r, 'project_id', `app[${i}]`), 'string', `app[${i}].project_id`);
        assertType(reqObj(r, 'users', `app[${i}]`), 'number', `app[${i}].users`);
        assertType(reqObj(r, 'grants_accepted', `app[${i}]`), 'number', `app[${i}].grants_accepted`);
        assertType(reqObj(r, 'grants_rejected', `app[${i}]`), 'number', `app[${i}].grants_rejected`);
        assertType(reqObj(r, 'reject_rate', `app[${i}]`), 'number', `app[${i}].reject_rate`, true);
        assertType(reqObj(r, 'fast_grants', `app[${i}]`), 'number', `app[${i}].fast_grants`);
        assertType(reqObj(r, 'fast_grant_pct', `app[${i}]`), 'number', `app[${i}].fast_grant_pct`, true);
        assertType(reqObj(r, 'median_decision_seconds', `app[${i}]`), 'number', `app[${i}].median_decision_seconds`, true);
        assertType(reqObj(r, 'zero_reject_high_volume_users', `app[${i}]`), 'number', `app[${i}].zero_reject_high_volume_users`);
      });
    }
    const ae = reqObj(sec, 'audit_export', 'security');
    assertType(ae, 'object', 'security.audit_export');
    if (ae) {
      assertType(reqObj(ae, 'configured', 'audit_export'), 'boolean', 'audit_export.configured');
      assertType(reqObj(ae, 'note', 'audit_export'), 'string', 'audit_export.note');
    }
  }

  const adopt = reqObj(admin, 'adoption', 'root');
  assertType(adopt, 'object', 'adoption');
  if (adopt) {
    const cust = reqObj(adopt, 'customization', 'adoption');
    assertType(cust, 'object', 'adoption.customization');
    if (cust) {
      assertType(reqObj(cust, 'wau', 'customization'), 'number', 'customization.wau');
      assertType(reqObj(cust, 'skills_pct', 'customization'), 'number', 'customization.skills_pct', true);
      assertType(reqObj(cust, 'subagents_pct', 'customization'), 'number', 'customization.subagents_pct', true);
      assertType(reqObj(cust, 'slash_pct', 'customization'), 'number', 'customization.slash_pct', true);
      assertType(reqObj(cust, 'hooks_pct', 'customization'), 'number', 'customization.hooks_pct', true);
      const cw = reqObj(cust, 'weekly', 'customization');
      assertType(cw, 'array', 'customization.weekly');
      if (Array.isArray(cw)) {
        cw.forEach((r, i) => {
          assertType(reqObj(r, 'week_start', `cw[${i}]`), 'string', `cw[${i}].week_start`);
          assertType(reqObj(r, 'skills_pct', `cw[${i}]`), 'number', `cw[${i}].skills_pct`, true);
          assertType(reqObj(r, 'subagents_pct', `cw[${i}]`), 'number', `cw[${i}].subagents_pct`, true);
          assertType(reqObj(r, 'slash_pct', `cw[${i}]`), 'number', `cw[${i}].slash_pct`, true);
          assertType(reqObj(r, 'hooks_pct', `cw[${i}]`), 'number', `cw[${i}].hooks_pct`, true);
        });
      }
      const tsc = reqObj(cust, 'top_slash_commands', 'customization');
      assertType(tsc, 'array', 'customization.top_slash_commands');
      if (Array.isArray(tsc)) {
        tsc.forEach((r, i) => {
          assertType(reqObj(r, 'command', `tsc[${i}]`), 'string', `tsc[${i}].command`);
          assertType(reqObj(r, 'uses', `tsc[${i}]`), 'number', `tsc[${i}].uses`);
          assertType(reqObj(r, 'users', `tsc[${i}]`), 'number', `tsc[${i}].users`);
        });
      }
    }
    const smw = reqObj(adopt, 'surface_mix_weekly', 'adoption');
    assertType(smw, 'array', 'adoption.surface_mix_weekly');
    if (Array.isArray(smw)) {
      smw.forEach((r, i) => {
        assertType(reqObj(r, 'week_start', `smw[${i}]`), 'string', `smw[${i}].week_start`);
        assertType(reqObj(r, 'client_name', `smw[${i}]`), 'string', `smw[${i}].client_name`);
        assertType(reqObj(r, 'users', `smw[${i}]`), 'number', `smw[${i}].users`);
      });
    }
    assertType(reqObj(adopt, 'multi_surface_users_pct', 'adoption'), 'number', 'adoption.multi_surface_users_pct', true);
  }

  const fleet = reqObj(admin, 'fleet', 'root');
  assertType(fleet, 'object', 'fleet');
  if (fleet) {
    const vdw = reqObj(fleet, 'version_distribution_weekly', 'fleet');
    assertType(vdw, 'array', 'fleet.version_distribution_weekly');
    if (Array.isArray(vdw)) {
      vdw.forEach((r, i) => {
        assertType(reqObj(r, 'week_start', `vdw[${i}]`), 'string', `vdw[${i}].week_start`);
        assertType(reqObj(r, 'client_version', `vdw[${i}]`), 'string', `vdw[${i}].client_version`);
        assertType(reqObj(r, 'users', `vdw[${i}]`), 'number', `vdw[${i}].users`);
      });
    }
  }

  return errors;
}

if (process.argv.includes('--check')) {
  if (!fs.existsSync(OUT_PATH)) {
    console.error(`Missing ${OUT_PATH}`);
    process.exit(1);
  }
  const admin = JSON.parse(fs.readFileSync(OUT_PATH, 'utf8'));
  const errs = validateContract(admin);
  if (errs.length > 0) {
    console.error(`Contract check failed (${errs.length} errors): ${errs.slice(0, 5).join('; ')}`);
    process.exit(1);
  }
  console.log(`admin.json contract check passed (${admin.alerts.length} alerts, window ${admin.window.start}..${admin.window.end})`);
  process.exit(0);
}

const config = readJson(CONFIG_PATH, {
  window_days: 30,
  corporate_domains: ['cymbalgroup.com'],
  project_budgets_usd: {},
  budget_alert_thresholds: [0.5, 0.8, 1.0],
  fast_approval_seconds: 2,
  abandon_idle_hours: 24,
  rightsizing_max_steps: 3,
  runaway_min_steps: 100
});

const adoptionRows = readJson(path.join(DATA_DIR, 'adoption.json'), []);
const trustRows = readJson(path.join(DATA_DIR, 'trust_quality.json'), []);
const econRows = readJson(path.join(DATA_DIR, 'token_economics.json'), []);
const rateCardRows = readJson(path.join(RAW_DIR, 'rate_card.json'), []);
const showbackRows = readJson(path.join(RAW_DIR, 'project_showback.json'), []);
const outcomeRows = readJson(path.join(RAW_DIR, 'trajectory_outcomes.json'), []);
const privacyRows = readJson(path.join(RAW_DIR, 'privacy_posture.json'), []);
const tableOptRows = readJson(path.join(RAW_DIR, 'table_options.json'), []);
const domainRows = readJson(path.join(RAW_DIR, 'identity_domains.json'), []);
const auxRows = readJson(path.join(RAW_DIR, 'aux_overhead.json'), []);
const approvalRows = readJson(path.join(RAW_DIR, 'approval_posture.json'), []);
const customRows = readJson(path.join(RAW_DIR, 'customization.json'), []);

const allDates = [
  ...adoptionRows.map(r => r.event_date),
  ...showbackRows.map(r => r.event_date),
  ...auxRows.map(r => r.event_date)
].filter(Boolean).sort();

const windowDays = num(config.window_days) || 30;
const windowEnd = allDates.length ? allDates[allDates.length - 1] : '2026-09-29';
const windowStart = addDays(windowEnd, -(windowDays - 1));
const prevEnd = addDays(windowStart, -1);
const prevStart = addDays(prevEnd, -(windowDays - 1));

const wauEnd = windowEnd;
const wauStart = addDays(wauEnd, -6);
const wauPrevEnd = addDays(wauStart, -1);
const wauPrevStart = addDays(wauPrevEnd, -6);

const inWindow = d => d >= windowStart && d <= windowEnd;
const inPrevWindow = d => d >= prevStart && d <= prevEnd;
const inWau = d => d >= wauStart && d <= wauEnd;
const inPrevWau = d => d >= wauPrevStart && d <= wauPrevEnd;

const rate_card = rateCardRows.map(r => ({
  model: String(r.model || ''),
  usd_per_1m_tokens: num(r.usd_per_1m_tokens),
  source: String(r.source || '')
}));

// Max timestamp across trajectories for abandon_idle_hours check
let maxTsMs = parseTsMs(`${windowEnd}T23:59:59Z`);
for (const r of outcomeRows) {
  const ms = parseTsMs(r.last_ts);
  if (ms !== null && (maxTsMs === null || ms > maxTsMs)) maxTsMs = ms;
}
const idleCutoffMs = (num(config.abandon_idle_hours) || 24) * 3600 * 1000;

const winOutcomes = outcomeRows.filter(r => {
  const d = tsToDateStr(r.first_ts);
  return inWindow(d);
});
const prevOutcomes = outcomeRows.filter(r => {
  const d = tsToDateStr(r.first_ts);
  return inPrevWindow(d);
});

function summarizeOutcomes(rows) {
  let trajectories = 0;
  let resolved = 0;
  let abandoned = 0;
  let in_flight = 0;
  let est_cost_usd = 0;
  let resolved_cost_usd = 0;
  let abandoned_cost_usd = 0;
  let acc = 0;
  let mod = 0;
  let rej = 0;

  for (const r of rows) {
    trajectories += 1;
    const cost = num(r.est_cost_usd);
    const isResolved = r.resolved === true || String(r.resolved).toLowerCase() === 'true';
    const lastMs = parseTsMs(r.last_ts);
    const isIdle = lastMs !== null && maxTsMs !== null ? (maxTsMs - lastMs) >= idleCutoffMs : true;

    est_cost_usd += cost;
    if (isResolved) {
      resolved += 1;
      resolved_cost_usd += cost;
    } else if (isIdle) {
      abandoned += 1;
      abandoned_cost_usd += cost;
    } else {
      in_flight += 1;
    }

    acc += num(r.proposals_accepted);
    mod += num(r.proposals_modified);
    rej += num(r.proposals_rejected);
  }

  return {
    trajectories,
    resolved,
    abandoned,
    in_flight,
    est_cost_usd: round(est_cost_usd, 4) ?? 0,
    resolved_cost_usd: round(resolved_cost_usd, 4) ?? 0,
    abandoned_cost_usd: round(abandoned_cost_usd, 4) ?? 0,
    cost_per_resolved_usd: safeDiv(est_cost_usd, resolved, 1, 4),
    abandoned_cost_pct: safeDiv(abandoned_cost_usd, est_cost_usd, 100, 2),
    rework_rate: safeDiv(mod + rej, acc + mod + rej, 1, 4)
  };
}

const currSummary = summarizeOutcomes(winOutcomes);
const prevSummary = summarizeOutcomes(prevOutcomes);

// Value: proposal_outcomes_by_model & outcomes_by_model_tier
const byModelExp = new Map();
for (const r of winOutcomes) {
  const model = String(r.model || 'unspecified');
  const experience = String(r.experience || 'unspecified');
  const key = `${model}||${experience}`;
  if (!byModelExp.has(key)) {
    byModelExp.set(key, {
      model,
      experience,
      accepted: 0,
      modified: 0,
      rejected: 0,
      trajectories: 0,
      resolved: 0,
      est_cost_usd: 0,
      abandoned_cost_usd: 0
    });
  }
  const item = byModelExp.get(key);
  item.accepted += num(r.proposals_accepted);
  item.modified += num(r.proposals_modified);
  item.rejected += num(r.proposals_rejected);
  item.trajectories += 1;
  const cost = num(r.est_cost_usd);
  item.est_cost_usd += cost;
  const isResolved = r.resolved === true || String(r.resolved).toLowerCase() === 'true';
  const lastMs = parseTsMs(r.last_ts);
  const isIdle = lastMs !== null && maxTsMs !== null ? (maxTsMs - lastMs) >= idleCutoffMs : true;
  if (isResolved) {
    item.resolved += 1;
  } else if (isIdle) {
    item.abandoned_cost_usd += cost;
  }
}

const proposal_outcomes_by_model = Array.from(byModelExp.values())
  .map(item => {
    const total = item.accepted + item.modified + item.rejected;
    return {
      model: item.model,
      experience: item.experience,
      accepted: item.accepted,
      modified: item.modified,
      rejected: item.rejected,
      total,
      rework_rate: safeDiv(item.modified + item.rejected, total, 1, 4)
    };
  })
  .filter(item => item.total > 0)
  .sort((a, b) => b.total - a.total);

const outcomes_by_model_tier = Array.from(byModelExp.values())
  .map(item => ({
    model: item.model,
    experience: item.experience,
    trajectories: item.trajectories,
    resolved: item.resolved,
    resolution_rate: safeDiv(item.resolved, item.trajectories, 1, 4),
    est_cost_usd: round(item.est_cost_usd, 4) ?? 0,
    cost_per_resolved_usd: safeDiv(item.est_cost_usd, item.resolved, 1, 4),
    abandoned_cost_usd: round(item.abandoned_cost_usd, 4) ?? 0
  }))
  .sort((a, b) => b.trajectories - a.trajectories);

const proposalsByWeek = new Map();
for (const r of trustRows) {
  if (!r.event_date || !inWindow(r.event_date)) continue;
  const wk = getMonday(r.event_date);
  if (!proposalsByWeek.has(wk)) {
    proposalsByWeek.set(wk, { week_start: wk, accepted: 0, modified: 0, rejected: 0 });
  }
  const item = proposalsByWeek.get(wk);
  item.accepted += num(r.proposals_accepted);
  item.modified += num(r.proposals_modified);
  item.rejected += num(r.proposals_rejected);
}
const proposal_outcomes_weekly = Array.from(proposalsByWeek.values())
  .sort((a, b) => a.week_start.localeCompare(b.week_start))
  .map(w => ({
    week_start: w.week_start,
    accepted: w.accepted,
    modified: w.modified,
    rejected: w.rejected,
    rework_rate: safeDiv(w.modified + w.rejected, w.accepted + w.modified + w.rejected, 1, 4)
  }));

// Cost: project_showback & project_daily
const projMap = new Map();
const projDailyMap = new Map();
for (const r of showbackRows) {
  if (!r.event_date || !inWindow(r.event_date)) continue;
  const pid = String(r.project_id || 'unspecified');
  const pnum = String(r.project_number || 'unspecified');
  if (!projMap.has(pid)) {
    projMap.set(pid, {
      project_id: pid,
      project_number: pnum,
      userSet: new Set(),
      trajectories: 0,
      inferences: 0,
      total_tokens: 0,
      est_cost_usd: 0
    });
  }
  const p = projMap.get(pid);
  if (r.user_email) p.userSet.add(r.user_email);
  p.trajectories += num(r.trajectories);
  p.inferences += num(r.inferences);
  p.total_tokens += num(r.total_tokens);
  p.est_cost_usd += num(r.est_cost_usd);

  const dKey = `${r.event_date}||${pid}`;
  projDailyMap.set(dKey, (projDailyMap.get(dKey) || 0) + num(r.est_cost_usd));
}

// Reconcile distinct trajectories per project from winOutcomes when available
const projTrajSet = new Map();
for (const r of winOutcomes) {
  const pid = String(r.project_id || 'unspecified');
  if (!projTrajSet.has(pid)) projTrajSet.set(pid, new Set());
  projTrajSet.get(pid).add(r.trajectory_id);
}

const budgets = config.project_budgets_usd || {};
const thresholds = Array.isArray(config.budget_alert_thresholds) && config.budget_alert_thresholds.length
  ? [...config.budget_alert_thresholds].sort((a, b) => a - b)
  : [0.5, 0.8, 1.0];
const warnThreshold = (thresholds[1] ?? 0.8) * 100;
const overThreshold = (thresholds[thresholds.length - 1] ?? 1.0) * 100;

const project_showback = Array.from(projMap.values())
  .map(p => {
    const rawBudget = budgets[p.project_id];
    const hasBudget = rawBudget !== undefined && rawBudget !== null && Number.isFinite(Number(rawBudget)) && Number(rawBudget) > 0;
    const budget_usd = hasBudget ? round(Number(rawBudget), 2) : null;
    const est_cost_usd = round(p.est_cost_usd, 4) ?? 0;
    const budget_pct = hasBudget ? safeDiv(est_cost_usd, budget_usd, 100, 2) : null;
    let status = 'no_budget';
    if (hasBudget && budget_pct !== null) {
      if (budget_pct >= overThreshold) status = 'over';
      else if (budget_pct >= warnThreshold) status = 'warn';
      else status = 'ok';
    }
    return {
      project_id: p.project_id,
      project_number: p.project_number,
      users: p.userSet.size,
      trajectories: projTrajSet.has(p.project_id) ? projTrajSet.get(p.project_id).size : p.trajectories,
      inferences: p.inferences,
      total_tokens: p.total_tokens,
      est_cost_usd,
      budget_usd,
      budget_pct,
      status
    };
  })
  .sort((a, b) => b.est_cost_usd - a.est_cost_usd);

const project_daily = Array.from(projDailyMap.entries())
  .map(([k, cost]) => {
    const [event_date, project_id] = k.split('||');
    return {
      event_date,
      project_id,
      est_cost_usd: round(cost, 4) ?? 0
    };
  })
  .sort((a, b) => a.event_date.localeCompare(b.event_date) || a.project_id.localeCompare(b.project_id));

// Aux overhead by version (ordered by first_seen across dataset, metrics from window or all-time for version)
const verFirstSeen = new Map();
for (const r of auxRows) {
  const key = `${r.client_name}||${r.client_version}`;
  if (!verFirstSeen.has(key) || r.event_date < verFirstSeen.get(key)) {
    verFirstSeen.set(key, r.event_date);
  }
}
const auxByVerMap = new Map();
const auxWeeklyMap = new Map();
for (const r of auxRows) {
  if (!r.event_date || !inWindow(r.event_date)) continue;
  const key = `${r.client_name}||${r.client_version}`;
  if (!auxByVerMap.has(key)) {
    auxByVerMap.set(key, {
      client_name: String(r.client_name || 'unspecified'),
      client_version: String(r.client_version || 'unspecified'),
      total_calls: 0,
      aux_calls: 0,
      total_tokens: 0,
      aux_tokens: 0,
      first_seen: verFirstSeen.get(key) || r.event_date
    });
  }
  const v = auxByVerMap.get(key);
  v.total_calls += num(r.total_calls);
  v.aux_calls += num(r.aux_calls);
  v.total_tokens += num(r.total_tokens);
  v.aux_tokens += num(r.aux_tokens);

  const wk = getMonday(r.event_date);
  if (!auxWeeklyMap.has(wk)) {
    auxWeeklyMap.set(wk, { week_start: wk, total_tokens: 0, aux_tokens: 0 });
  }
  const w = auxWeeklyMap.get(wk);
  w.total_tokens += num(r.total_tokens);
  w.aux_tokens += num(r.aux_tokens);
}

const aux_overhead_by_version = Array.from(auxByVerMap.values())
  .map(v => ({
    client_name: v.client_name,
    client_version: v.client_version,
    total_calls: v.total_calls,
    aux_calls: v.aux_calls,
    aux_call_pct: safeDiv(v.aux_calls, v.total_calls, 100, 2),
    total_tokens: v.total_tokens,
    aux_tokens: v.aux_tokens,
    aux_token_pct: safeDiv(v.aux_tokens, v.total_tokens, 100, 2),
    first_seen: v.first_seen
  }))
  .sort((a, b) => a.first_seen.localeCompare(b.first_seen) || compareVersions(a.client_version, b.client_version));

const aux_overhead_weekly = Array.from(auxWeeklyMap.values())
  .sort((a, b) => a.week_start.localeCompare(b.week_start))
  .map(w => ({
    week_start: w.week_start,
    aux_token_pct: safeDiv(w.aux_tokens, w.total_tokens, 100, 2)
  }));

// Automation vs seat weekly (from view 03 token_economics)
const autoSeatMap = new Map();
for (const r of econRows) {
  if (!r.event_date || !inWindow(r.event_date)) continue;
  const wk = getMonday(r.event_date);
  const tier = String(r.subscription_tier_type || 'SEAT_INCLUDED');
  const key = `${wk}||${tier}`;
  autoSeatMap.set(key, (autoSeatMap.get(key) || 0) + num(r.total_tokens));
}
const automation_vs_seat_weekly = Array.from(autoSeatMap.entries())
  .map(([k, total_tokens]) => {
    const [week_start, subscription_tier_type] = k.split('||');
    return { week_start, subscription_tier_type, total_tokens };
  })
  .sort((a, b) => a.week_start.localeCompare(b.week_start) || a.subscription_tier_type.localeCompare(b.subscription_tier_type));

// Rightsizing (only experiences ending in -high)
const maxShortSteps = num(config.rightsizing_max_steps) || 3;
const rzMap = new Map();
for (const r of winOutcomes) {
  const exp = String(r.experience || '');
  if (!exp.endsWith('-high')) continue;
  const pid = String(r.project_id || 'unspecified');
  const key = `${pid}||${exp}`;
  if (!rzMap.has(key)) {
    rzMap.set(key, {
      project_id: pid,
      experience: exp,
      trajectories: 0,
      short_trajectories: 0,
      est_cost_usd: 0,
      short_cost_usd: 0,
      resolved: 0
    });
  }
  const item = rzMap.get(key);
  const steps = num(r.steps);
  const cost = num(r.est_cost_usd);
  const isResolved = r.resolved === true || String(r.resolved).toLowerCase() === 'true';
  item.trajectories += 1;
  item.est_cost_usd += cost;
  if (isResolved) item.resolved += 1;
  if (steps <= maxShortSteps) {
    item.short_trajectories += 1;
    item.short_cost_usd += cost;
  }
}
const rightsizing = Array.from(rzMap.values())
  .map(item => ({
    project_id: item.project_id,
    experience: item.experience,
    trajectories: item.trajectories,
    short_trajectories: item.short_trajectories,
    short_pct: safeDiv(item.short_trajectories, item.trajectories, 100, 2),
    est_cost_usd: round(item.est_cost_usd, 4) ?? 0,
    short_cost_usd: round(item.short_cost_usd, 4) ?? 0,
    resolution_rate: safeDiv(item.resolved, item.trajectories, 1, 4)
  }))
  .sort((a, b) => b.short_cost_usd - a.short_cost_usd);

// Runaway sessions (steps >= runaway_min_steps, top 20 by steps)
const minRunawaySteps = num(config.runaway_min_steps) || 100;
const runaway_sessions = winOutcomes
  .filter(r => num(r.steps) >= minRunawaySteps)
  .sort((a, b) => num(b.steps) - num(a.steps))
  .slice(0, 20)
  .map(r => ({
    trajectory_id: String(r.trajectory_id),
    project_id: String(r.project_id || 'unspecified'),
    user_email: String(r.user_email || ''),
    steps: num(r.steps),
    total_tokens: num(r.total_tokens),
    est_cost_usd: round(num(r.est_cost_usd), 4) ?? 0,
    first_ts: String(r.first_ts || ''),
    last_ts: String(r.last_ts || ''),
    resolved: r.resolved === true || String(r.resolved).toLowerCase() === 'true'
  }));

// Security: privacy posture
const pfRow = privacyRows[0] || {};
let partitionExpDays = null;
if (tableOptRows.length > 0 && tableOptRows[0].option_value != null) {
  const parsed = Number(tableOptRows[0].option_value);
  if (Number.isFinite(parsed)) partitionExpDays = parsed;
}
const privacy_facts = {
  requests_total: num(pfRow.requests_total),
  requests_with_prompt_text: num(pfRow.requests_with_prompt_text),
  responses_total: num(pfRow.responses_total),
  responses_with_candidates: num(pfRow.responses_with_candidates),
  oldest_request_ts: String(pfRow.oldest_request_ts || ''),
  partition_expiration_days: partitionExpDays,
  distinct_user_emails: num(pfRow.distinct_user_emails)
};

const privacy_checks = [
  {
    id: 'prompt_text_stored',
    label: 'Prompt text excluded from inference_request',
    status: privacy_facts.requests_with_prompt_text > 0 ? 'FAIL' : 'PASS',
    detail: privacy_facts.requests_with_prompt_text > 0
      ? `${privacy_facts.requests_with_prompt_text.toLocaleString()} of ${privacy_facts.requests_total.toLocaleString()} request rows store prompt text in input.messages`
      : '0 request rows contain prompt text'
  },
  {
    id: 'response_candidates_stripped',
    label: 'Response candidates stripped from inference_response',
    status: privacy_facts.responses_with_candidates === 0 ? 'PASS' : 'FAIL',
    detail: privacy_facts.responses_with_candidates === 0
      ? '0 response rows contain candidate output messages'
      : `${privacy_facts.responses_with_candidates.toLocaleString()} of ${privacy_facts.responses_total.toLocaleString()} response rows contain candidate output messages`
  },
  {
    id: 'partition_expiration',
    label: 'Table partition expiration configured',
    status: privacy_facts.partition_expiration_days !== null ? 'PASS' : 'WARN',
    detail: privacy_facts.partition_expiration_days !== null
      ? `Partition expiration set to ${privacy_facts.partition_expiration_days} days`
      : 'No partition_expiration_days set on inference_request table'
  },
  {
    id: 'emails_unmasked',
    label: 'User email identifiers masked',
    status: privacy_facts.distinct_user_emails > 0 ? 'WARN' : 'PASS',
    detail: privacy_facts.distinct_user_emails > 0
      ? `${privacy_facts.distinct_user_emails.toLocaleString()} distinct unmasked user emails present in logs`
      : 'No unmasked user emails found'
  }
];

// Security: identity_domains
const corpSet = new Set((config.corporate_domains || []).map(d => String(d).toLowerCase()));
const domUsersExact = new Map();
for (const r of showbackRows) {
  if (!r.user_email) continue;
  const parts = String(r.user_email).toLowerCase().split('@');
  const dom = parts.length > 1 ? parts[1] : 'unknown';
  if (!domUsersExact.has(dom)) domUsersExact.set(dom, new Set());
  domUsersExact.get(dom).add(String(r.user_email).toLowerCase());
}

const domAgg = new Map();
for (const r of domainRows) {
  const dom = String(r.domain || 'unknown').toLowerCase();
  if (!domAgg.has(dom)) {
    domAgg.set(dom, {
      domain: dom,
      usersSum: 0,
      projectsSet: new Set(),
      inferences: 0,
      first_seen: String(r.first_seen || ''),
      last_seen: String(r.last_seen || '')
    });
  }
  const d = domAgg.get(dom);
  d.usersSum += num(r.users);
  if (r.project_id) d.projectsSet.add(r.project_id);
  d.inferences += num(r.inferences);
  const fsStr = String(r.first_seen || '');
  const lsStr = String(r.last_seen || '');
  if (fsStr && (!d.first_seen || fsStr < d.first_seen)) d.first_seen = fsStr;
  if (lsStr && (!d.last_seen || lsStr > d.last_seen)) d.last_seen = lsStr;
}
const identity_domains = Array.from(domAgg.values())
  .map(d => ({
    domain: d.domain,
    users: domUsersExact.has(d.domain) ? domUsersExact.get(d.domain).size : d.usersSum,
    projects: d.projectsSet.size,
    inferences: d.inferences,
    is_corporate: corpSet.has(d.domain),
    first_seen: tsToDateStr(d.first_seen),
    last_seen: tsToDateStr(d.last_seen)
  }))
  .sort((a, b) => b.inferences - a.inferences);

// Security: approval_posture_by_project
const appProjMap = new Map();
for (const r of approvalRows) {
  const pid = String(r.project_id || 'unspecified');
  if (!appProjMap.has(pid)) {
    appProjMap.set(pid, {
      project_id: pid,
      users: 0,
      grants_accepted: 0,
      grants_rejected: 0,
      fast_grants: 0,
      medians: [],
      zero_reject_high_volume_users: 0
    });
  }
  const p = appProjMap.get(pid);
  const acc = num(r.grants_accepted);
  const rej = num(r.grants_rejected);
  const total = acc + rej;
  p.users += 1;
  p.grants_accepted += acc;
  p.grants_rejected += rej;
  p.fast_grants += num(r.fast_grants);
  if (r.median_decision_seconds !== null && r.median_decision_seconds !== undefined && Number.isFinite(Number(r.median_decision_seconds))) {
    p.medians.push(Number(r.median_decision_seconds));
  }
  if (total >= 50 && rej === 0) {
    p.zero_reject_high_volume_users += 1;
  }
}
const approval_posture_by_project = Array.from(appProjMap.values())
  .map(p => {
    const total = p.grants_accepted + p.grants_rejected;
    const sortedMed = p.medians.sort((a, b) => a - b);
    const medVal = sortedMed.length
      ? round(sortedMed[Math.floor(sortedMed.length / 2)], 2)
      : null;
    return {
      project_id: p.project_id,
      users: p.users,
      grants_accepted: p.grants_accepted,
      grants_rejected: p.grants_rejected,
      reject_rate: safeDiv(p.grants_rejected, total, 1, 4),
      fast_grants: p.fast_grants,
      fast_grant_pct: safeDiv(p.fast_grants, total, 100, 2),
      median_decision_seconds: medVal,
      zero_reject_high_volume_users: p.zero_reject_high_volume_users
    };
  })
  .sort((a, b) => (b.grants_accepted + b.grants_rejected) - (a.grants_accepted + a.grants_rejected));

// Adoption & Fleet
const wauUsers = new Set();
const wauPrevUsers = new Set();
const activeUsersByWeek = new Map();
const surfaceByWeek = new Map();
const userSurfacesInWau = new Map();
const versionByWeek = new Map();
const wauVersionUsers = new Map();

for (const r of adoptionRows) {
  const d = r.event_date;
  const u = r.user_email;
  if (!d || !u) continue;
  if (inWau(d)) {
    wauUsers.add(u);
    if (!userSurfacesInWau.has(u)) userSurfacesInWau.set(u, new Set());
    userSurfacesInWau.get(u).add(String(r.client_name || 'unspecified'));

    const ver = String(r.client_version || 'unspecified');
    if (!wauVersionUsers.has(ver)) wauVersionUsers.set(ver, new Set());
    wauVersionUsers.get(ver).add(u);
  }
  if (inPrevWau(d)) {
    wauPrevUsers.add(u);
  }
  if (inWindow(d)) {
    const wk = getMonday(d);
    if (!activeUsersByWeek.has(wk)) activeUsersByWeek.set(wk, new Set());
    activeUsersByWeek.get(wk).add(u);

    const sKey = `${wk}||${r.client_name || 'unspecified'}`;
    if (!surfaceByWeek.has(sKey)) surfaceByWeek.set(sKey, new Set());
    surfaceByWeek.get(sKey).add(u);

    const vKey = `${wk}||${r.client_version || 'unspecified'}`;
    if (!versionByWeek.has(vKey)) versionByWeek.set(vKey, new Set());
    versionByWeek.get(vKey).add(u);
  }
}

const wauCount = wauUsers.size;
const wauPrevCount = wauPrevUsers.size;
let multiSurfaceCount = 0;
for (const sSet of userSurfacesInWau.values()) {
  if (sSet.size >= 2) multiSurfaceCount += 1;
}
const multi_surface_users_pct = safeDiv(multiSurfaceCount, wauCount, 100, 2) ?? 0;

const surface_mix_weekly = Array.from(surfaceByWeek.entries())
  .map(([k, set]) => {
    const [week_start, client_name] = k.split('||');
    return { week_start, client_name, users: set.size };
  })
  .sort((a, b) => a.week_start.localeCompare(b.week_start) || a.client_name.localeCompare(b.client_name));

const version_distribution_weekly = Array.from(versionByWeek.entries())
  .map(([k, set]) => {
    const [week_start, client_version] = k.split('||');
    return { week_start, client_version, users: set.size };
  })
  .sort((a, b) => a.week_start.localeCompare(b.week_start) || compareVersions(a.client_version, b.client_version));

const allVersionsSeen = Array.from(wauVersionUsers.keys()).sort(compareVersions);
const current_version = allVersionsSeen.length
  ? allVersionsSeen[allVersionsSeen.length - 1]
  : (aux_overhead_by_version.length ? aux_overhead_by_version[aux_overhead_by_version.length - 1].client_version : 'unspecified');
const usersOnCurrentVer = wauVersionUsers.has(current_version) ? wauVersionUsers.get(current_version).size : 0;
const fleet_on_current_version_pct = safeDiv(usersOnCurrentVer, wauCount, 100, 2) ?? 0;

// Customization adoption (pct = share of WAU who used it in last 7 days; weekly = share of weekly active users)
const wauSkillUsers = new Set();
const wauSubagentUsers = new Set();
const wauSlashUsers = new Set();
const wauHookUsers = new Set();
const custByWeek = new Map();
const slashCmdStats = new Map();

for (const wk of activeUsersByWeek.keys()) {
  custByWeek.set(wk, {
    skills: new Set(),
    subagents: new Set(),
    slash: new Set(),
    hooks: new Set()
  });
}

for (const r of customRows) {
  const d = r.event_date;
  const u = r.user_email;
  if (!d || !u) continue;
  const hasSkill = r.uses_skill === true || String(r.uses_skill).toLowerCase() === 'true';
  const hasSub = r.uses_subagent === true || String(r.uses_subagent).toLowerCase() === 'true';
  const hasSlash = r.uses_slash === true || String(r.uses_slash).toLowerCase() === 'true';
  const hasHook = r.uses_hook === true || String(r.uses_hook).toLowerCase() === 'true';

  if (inWau(d) && wauUsers.has(u)) {
    if (hasSkill) wauSkillUsers.add(u);
    if (hasSub) wauSubagentUsers.add(u);
    if (hasSlash) wauSlashUsers.add(u);
    if (hasHook) wauHookUsers.add(u);
  }

  if (inWindow(d)) {
    const wk = getMonday(d);
    if (!custByWeek.has(wk)) {
      custByWeek.set(wk, { skills: new Set(), subagents: new Set(), slash: new Set(), hooks: new Set() });
    }
    const cw = custByWeek.get(wk);
    if (hasSkill) cw.skills.add(u);
    if (hasSub) cw.subagents.add(u);
    if (hasSlash) cw.slash.add(u);
    if (hasHook) cw.hooks.add(u);

    const cmds = Array.isArray(r.slash_commands) ? r.slash_commands : [];
    for (const cmd of cmds) {
      if (!cmd) continue;
      if (!slashCmdStats.has(cmd)) slashCmdStats.set(cmd, { command: String(cmd), uses: 0, userSet: new Set() });
      const st = slashCmdStats.get(cmd);
      st.uses += 1;
      st.userSet.add(u);
    }
  }
}

const custWeekly = Array.from(custByWeek.entries())
  .sort((a, b) => a[0].localeCompare(b[0]))
  .map(([wk, sets]) => {
    const denom = activeUsersByWeek.has(wk) ? activeUsersByWeek.get(wk).size : 0;
    return {
      week_start: wk,
      skills_pct: safeDiv(sets.skills.size, denom, 100, 2) ?? 0,
      subagents_pct: safeDiv(sets.subagents.size, denom, 100, 2) ?? 0,
      slash_pct: safeDiv(sets.slash.size, denom, 100, 2) ?? 0,
      hooks_pct: safeDiv(sets.hooks.size, denom, 100, 2) ?? 0
    };
  });

const top_slash_commands = Array.from(slashCmdStats.values())
  .map(st => ({
    command: st.command,
    uses: st.uses,
    users: st.userSet.size
  }))
  .sort((a, b) => b.uses - a.uses);

// Alerts generation:
// 1. privacy FAIL checks
// 2. budget threshold crossings
// 3. external domains seen
// 4. runaway sessions count > 0
// 5. aux overhead regression (latest version aux_token_pct > 1.25x previous version)
const alerts = [];

const PRIVACY_ALERT_TITLES = {
  prompt_text_stored: 'Prompt text is stored in inference_request',
  response_candidates_stripped: 'Model output is stored in inference_response',
};

for (const chk of privacy_checks) {
  if (chk.status === 'FAIL') {
    alerts.push({
      severity: 'red',
      theme: 'security',
      title: PRIVACY_ALERT_TITLES[chk.id] || `Privacy check failed: ${chk.label}`,
      detail: chk.detail
    });
  }
}

for (const p of project_showback) {
  if (p.budget_usd !== null && p.budget_pct !== null) {
    const minThreshPct = (thresholds[0] ?? 0.5) * 100;
    if (p.budget_pct >= minThreshPct) {
      alerts.push({
        severity: p.budget_pct >= overThreshold ? 'red' : 'amber',
        theme: 'cost',
        title: `Budget threshold crossed: ${p.project_id}`,
        detail: `${p.project_id} is at ${p.budget_pct}% ($${p.est_cost_usd.toFixed(2)} of $${p.budget_usd.toFixed(2)} budget)`
      });
    }
  }
}

for (const d of identity_domains) {
  if (!d.is_corporate) {
    alerts.push({
      severity: 'amber',
      theme: 'security',
      title: `External email domain seen: ${d.domain}`,
      detail: `${d.users} user(s) and ${d.inferences.toLocaleString()} inferences from non-corporate domain ${d.domain}`
    });
  }
}

if (runaway_sessions.length > 0) {
  alerts.push({
    severity: 'amber',
    theme: 'cost',
    title: 'Runaway sessions detected',
    detail: `${runaway_sessions.length} trajectory session(s) reached >= ${minRunawaySteps} steps in the ${windowDays}d window`
  });
}

if (aux_overhead_by_version.length >= 2) {
  const latestVer = aux_overhead_by_version[aux_overhead_by_version.length - 1];
  const prevVer = aux_overhead_by_version[aux_overhead_by_version.length - 2];
  if (
    latestVer.aux_token_pct !== null &&
    prevVer.aux_token_pct !== null &&
    prevVer.aux_token_pct > 0 &&
    latestVer.aux_token_pct > 1.25 * prevVer.aux_token_pct
  ) {
    alerts.push({
      severity: 'amber',
      theme: 'fleet',
      title: `Aux overhead regression in v${latestVer.client_version}`,
      detail: `v${latestVer.client_version} aux token share (${latestVer.aux_token_pct}%) exceeds 1.25x v${prevVer.client_version} (${prevVer.aux_token_pct}%)`
    });
  }
}

const privacyPassing = privacy_checks.filter(c => c.status === 'PASS').length;

const adminData = {
  config,
  window: {
    start: windowStart,
    end: windowEnd,
    days: windowDays
  },
  rate_card,
  overview: {
    wau: wauCount,
    wau_prev: wauPrevCount,
    cost_per_resolved_usd: currSummary.cost_per_resolved_usd,
    cost_per_resolved_usd_prev: prevSummary.cost_per_resolved_usd,
    rework_rate: currSummary.rework_rate,
    rework_rate_prev: prevSummary.rework_rate,
    privacy_checks_passing: privacyPassing,
    privacy_checks_total: privacy_checks.length,
    current_version,
    fleet_on_current_version_pct
  },
  alerts,
  value: {
    proposal_outcomes_by_model,
    proposal_outcomes_weekly,
    outcomes_summary: {
      trajectories: currSummary.trajectories,
      resolved: currSummary.resolved,
      abandoned: currSummary.abandoned,
      in_flight: currSummary.in_flight,
      est_cost_usd: currSummary.est_cost_usd,
      resolved_cost_usd: currSummary.resolved_cost_usd,
      abandoned_cost_usd: currSummary.abandoned_cost_usd,
      cost_per_resolved_usd: currSummary.cost_per_resolved_usd,
      abandoned_cost_pct: currSummary.abandoned_cost_pct
    },
    outcomes_by_model_tier
  },
  cost: {
    project_showback,
    project_daily,
    aux_overhead_by_version,
    aux_overhead_weekly,
    automation_vs_seat_weekly,
    rightsizing,
    runaway_sessions
  },
  security: {
    privacy_checks,
    privacy_facts,
    identity_domains,
    approval_posture_by_project,
    audit_export: {
      configured: false,
      note: 'Scheduled export to GCS is not configured in this build.'
    }
  },
  adoption: {
    customization: {
      wau: wauCount,
      skills_pct: safeDiv(wauSkillUsers.size, wauCount, 100, 2) ?? 0,
      subagents_pct: safeDiv(wauSubagentUsers.size, wauCount, 100, 2) ?? 0,
      slash_pct: safeDiv(wauSlashUsers.size, wauCount, 100, 2) ?? 0,
      hooks_pct: safeDiv(wauHookUsers.size, wauCount, 100, 2) ?? 0,
      weekly: custWeekly,
      top_slash_commands
    },
    surface_mix_weekly,
    multi_surface_users_pct
  },
  fleet: {
    version_distribution_weekly
  }
};

const contractErrors = validateContract(adminData);
if (contractErrors.length > 0) {
  console.error(`Contract validation failed: ${contractErrors.join('; ')}`);
  process.exit(1);
}

fs.mkdirSync(DATA_DIR, { recursive: true });
fs.writeFileSync(OUT_PATH, JSON.stringify(adminData, null, 2) + '\n', 'utf8');
console.log(`Built ${OUT_PATH} (window ${windowStart}..${windowEnd}, WAU=${wauCount}, alerts=${alerts.length})`);
