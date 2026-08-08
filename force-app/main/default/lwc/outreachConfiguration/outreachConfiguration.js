import { LightningElement, track } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getBundle from "@salesforce/apex/OutreachConfigController.getBundle";
import saveEngine from "@salesforce/apex/OutreachConfigController.saveEngine";
import saveRule from "@salesforce/apex/OutreachConfigController.saveRule";
import saveCadence from "@salesforce/apex/OutreachConfigController.saveCadence";
import saveRulesEngine from "@salesforce/apex/OutreachConfigController.saveRulesEngine";
import saveOmni from "@salesforce/apex/OutreachConfigController.saveOmni";
import searchAccountsForPreview from "@salesforce/apex/OutreachConfigController.searchAccountsForPreview";
import previewCareItemComm from "@salesforce/apex/OutreachConfigController.previewCareItemComm";

const SECTIONS = [
  { id: "queue", label: "Queue & ranking" },
  { id: "rules", label: "Care item rules" },
  { id: "cadence", label: "Cadence policies" },
  { id: "integrations", label: "Integrations" },
  { id: "preview", label: "Comm preview" }
];

const COMMUNICATION_TOPIC_OPTIONS = [
  { label: "Marketing", value: "marketing" },
  { label: "Appointment reminders", value: "appointment_reminders" },
  { label: "Surveys", value: "surveys" },
  { label: "Educational", value: "educational" }
];

const COMMUNICATION_CLASS_OPTIONS = [
  { label: "Marketing", value: "Marketing" },
  { label: "Transactional", value: "Transactional" }
];

export default class OutreachConfiguration extends LightningElement {
  @track section = "queue";
  @track loading = true;
  @track saving = false;
  @track canManage = false;
  @track engine;
  @track rules = [];
  @track cadencePolicies = [];
  @track rulesEngine;
  @track omni;
  @track rankingStrategies = [];
  @track cadenceOptions = [];
  @track availableTeams = [];
  @track availableRoles = [];
  @track selectedRuleId;
  @track selectedCadenceName;
  @track draftRule;
  @track draftCadence;
  @track selectedTeams = [];
  @track selectedRoles = [];
  @track selectedAppointmentTypes = [];
  @track availableAppointmentTypes = [];
  error;
  @track previewQuery = "";
  @track previewResults = [];
  @track previewAccountId;
  @track previewRuleId;
  @track previewDto;
  @track previewLoading = false;

  connectedCallback() {
    this.refresh();
  }

  get sections() {
    return SECTIONS.map((s) => ({
      ...s,
      className:
        "oc-nav__btn" + (this.section === s.id ? " oc-nav__btn_active" : "")
    }));
  }

  get isQueue() {
    return this.section === "queue";
  }
  get isRules() {
    return this.section === "rules";
  }
  get isCadence() {
    return this.section === "cadence";
  }
  get isIntegrations() {
    return this.section === "integrations";
  }

  get accessBadgeClass() {
    return this.canManage ? "oc-badge oc-badge_ok" : "oc-badge oc-badge_locked";
  }
  get accessBadgeLabel() {
    return this.canManage ? "Edit access" : "Read only";
  }
  get saveDisabled() {
    return this.saving || !this.canManage;
  }
  get inputsDisabled() {
    return this.saving || !this.canManage;
  }

  get rankingOptions() {
    return (this.rankingStrategies || []).map((v) => ({ label: v, value: v }));
  }

  get cadencePicklist() {
    return (this.cadenceOptions || []).map((v) => ({ label: v, value: v }));
  }

  get communicationTopicOptions() {
    return COMMUNICATION_TOPIC_OPTIONS;
  }

  get communicationClassOptions() {
    return COMMUNICATION_CLASS_OPTIONS;
  }

  get teamOptions() {
    return this.buildServedOptions(this.availableTeams, this.selectedTeams);
  }

  get roleOptions() {
    return this.buildServedOptions(this.availableRoles, this.selectedRoles);
  }

  get appointmentTypeOptions() {
    return this.buildServedOptions(
      this.availableAppointmentTypes,
      this.selectedAppointmentTypes
    );
  }

  get showRangeFields() {
    return this.engine?.rankingStrategy === "RANGE";
  }
  get showRandomFields() {
    return this.engine?.rankingStrategy === "RANDOM";
  }
  get showWeightFields() {
    const s = this.engine?.rankingStrategy;
    return s && s !== "NEUTRAL";
  }

  get ruleRows() {
    return (this.rules || []).map((r) => ({
      ...r,
      enabledLabel: r.enabled ? "On" : "Off",
      enabledClass: r.enabled ? "oc-chip oc-chip_on" : "oc-chip oc-chip_off",
      pressureClass: r.bypassPressureGate ? "oc-chip oc-chip_warn" : "oc-chip",
      pressureLabel: r.bypassPressureGate ? "Bypass pressure" : "Standard",
      autoEmailLabel: r.autoSendEmail ? "On" : "Off",
      autoEmailClass: r.autoSendEmail
        ? "oc-chip oc-chip_on"
        : "oc-chip oc-chip_off",
      autoSmsLabel: r.autoSendSms ? "On" : "Off",
      autoSmsClass: r.autoSendSms ? "oc-chip oc-chip_on" : "oc-chip oc-chip_off",
      selected: r.developerName === this.selectedRuleId,
      servedTeamsLabel: this.formatServedLabel(r.servedTeams)
    }));
  }

  get cadenceRows() {
    return (this.cadencePolicies || []).map((c) => ({
      ...c,
      selected: c.developerName === this.selectedCadenceName
    }));
  }

  async refresh() {
    this.loading = true;
    this.error = undefined;
    try {
      const bundle = await getBundle();
      this.canManage = bundle?.access?.canManage === true;
      this.engine = bundle?.engine ? { ...bundle.engine } : null;
      this.rules = (bundle?.rules || []).map((r) => ({ ...r }));
      this.cadencePolicies = (bundle?.cadencePolicies || []).map((c) => ({
        ...c
      }));
      this.rulesEngine = bundle?.rulesEngine ? { ...bundle.rulesEngine } : null;
      this.omni = bundle?.omni ? { ...bundle.omni } : null;
      this.rankingStrategies = bundle?.rankingStrategies || [];
      this.cadenceOptions = bundle?.cadenceOptions || [];
      this.availableTeams = bundle?.availableTeams || [];
      this.availableRoles = bundle?.availableRoles || [];
      this.availableAppointmentTypes = bundle?.availableAppointmentTypes || [];
      if (this.selectedRuleId) {
        this.applyDraftRule(
          this.rules.find((r) => r.developerName === this.selectedRuleId)
        );
      }
      if (this.selectedCadenceName) {
        const match = this.cadencePolicies.find(
          (c) => c.developerName === this.selectedCadenceName
        );
        this.draftCadence = match ? { ...match } : null;
      }
    } catch (e) {
      this.error = this.messageFrom(e);
    } finally {
      this.loading = false;
    }
  }

  handleNav(event) {
    this.section = event.currentTarget.dataset.section;
  }

  handleEngineChange(event) {
    const field = event.target.dataset.field;
    if (!field || !this.engine) return;
    this.engine = { ...this.engine, [field]: this.valueFrom(event) };
  }

  handleRulesEngineChange(event) {
    const field = event.target.dataset.field;
    if (!field || !this.rulesEngine) return;
    this.rulesEngine = { ...this.rulesEngine, [field]: this.valueFrom(event) };
  }

  handleOmniChange(event) {
    const field = event.target.dataset.field;
    if (!field || !this.omni) return;
    this.omni = { ...this.omni, [field]: this.valueFrom(event) };
  }

  handleRuleChange(event) {
    const field = event.target.dataset.field;
    if (!field || !this.draftRule) return;
    this.draftRule = { ...this.draftRule, [field]: this.valueFrom(event) };
  }

  handleServedTeamsChange(event) {
    this.selectedTeams = [...(event.detail.value || [])];
    if (!this.draftRule) return;
    this.draftRule = {
      ...this.draftRule,
      servedTeams: this.joinServed(this.selectedTeams)
    };
  }

  handleServedRolesChange(event) {
    this.selectedRoles = [...(event.detail.value || [])];
    if (!this.draftRule) return;
    this.draftRule = {
      ...this.draftRule,
      servedRoles: this.joinServed(this.selectedRoles)
    };
  }

  handleAppointmentTypesChange(event) {
    this.selectedAppointmentTypes = [...(event.detail.value || [])];
    if (!this.draftRule) return;
    this.draftRule = {
      ...this.draftRule,
      requiredAppointmentTypes: this.joinServed(this.selectedAppointmentTypes)
    };
  }

  handleCadenceChange(event) {
    const field = event.target.dataset.field;
    if (!field || !this.draftCadence) return;
    this.draftCadence = {
      ...this.draftCadence,
      [field]: this.valueFrom(event)
    };
  }

  selectRule(event) {
    this.selectedRuleId = event.currentTarget.dataset.id;
    this.applyDraftRule(
      this.rules.find((r) => r.developerName === this.selectedRuleId)
    );
  }

  applyDraftRule(match) {
    this.draftRule = match ? { ...match } : null;
    this.selectedTeams = this.splitServed(match?.servedTeams);
    this.selectedRoles = this.splitServed(match?.servedRoles);
    this.selectedAppointmentTypes = this.splitServed(
      match?.requiredAppointmentTypes
    );
  }

  selectCadence(event) {
    const id = event.currentTarget.dataset.id;
    this.selectedCadenceName = id;
    const match = this.cadencePolicies.find((c) => c.developerName === id);
    this.draftCadence = match ? { ...match } : null;
  }

  async saveEngine() {
    const dto = {
      ...(this.engine || {}),
      developerName: this.engine?.developerName || "Default",
      masterLabel: this.engine?.masterLabel || "Default"
    };
    await this.runSave(() => saveEngine({ dto }), "Queue settings");
  }
  async saveSelectedRule() {
    if (this.draftRule) {
      this.draftRule = {
        ...this.draftRule,
        servedTeams: this.joinServed(this.selectedTeams),
        servedRoles: this.joinServed(this.selectedRoles),
        requiredAppointmentTypes: this.joinServed(this.selectedAppointmentTypes)
      };
    }
    await this.runSave(() => saveRule({ dto: this.draftRule }), "Rule");
  }
  async saveSelectedCadence() {
    await this.runSave(
      () => saveCadence({ dto: this.draftCadence }),
      "Cadence policy"
    );
  }
  async saveRulesEngine() {
    const dto = {
      ...(this.rulesEngine || {}),
      developerName: this.rulesEngine?.developerName || "Default",
      masterLabel: this.rulesEngine?.masterLabel || "Default"
    };
    await this.runSave(() => saveRulesEngine({ dto }), "RulesEngine");
  }
  async saveOmni() {
    const dto = {
      ...(this.omni || {}),
      developerName: this.omni?.developerName || "Default",
      masterLabel: this.omni?.masterLabel || "Default"
    };
    await this.runSave(() => saveOmni({ dto }), "Omni");
  }

  async runSave(fn, label) {
    if (!this.canManage) {
      this.toast("Read only", "You do not have edit access.", "warning");
      return;
    }
    this.saving = true;
    try {
      const result = await fn();
      this.toast(
        "Deploy queued",
        result?.message || `${label} save queued.`,
        "success"
      );
      await this.refresh();
    } catch (e) {
      this.toast("Save failed", this.messageFrom(e), "error");
    } finally {
      this.saving = false;
    }
  }

  buildServedOptions(available, selected) {
    const map = new Map();
    (available || []).forEach((v) => {
      if (v) map.set(v, { label: v, value: v });
    });
    (selected || []).forEach((v) => {
      if (v && !map.has(v)) {
        map.set(v, { label: `${v} (saved value)`, value: v });
      }
    });
    return [...map.values()].sort((a, b) => a.label.localeCompare(b.label));
  }

  splitServed(raw) {
    if (!raw) return [];
    return String(raw)
      .split(/[;\n,]/)
      .map((v) => v.trim())
      .filter(Boolean);
  }

  joinServed(values) {
    return (values || [])
      .map((v) => String(v).trim())
      .filter(Boolean)
      .join(";");
  }

  formatServedLabel(raw) {
    const parts = this.splitServed(raw);
    return parts.length ? parts.join(", ") : "All teams/roles";
  }

  valueFrom(event) {
    const t = event.target;
    if (t.type === "checkbox" || t.type === "toggle") return t.checked;
    if (Object.prototype.hasOwnProperty.call(event.detail || {}, "checked"))
      return event.detail.checked;
    if (Object.prototype.hasOwnProperty.call(event.detail || {}, "value"))
      return event.detail.value;
    return t.value;
  }

  messageFrom(e) {
    return (
      e?.body?.message ||
      e?.message ||
      (typeof e === "string" ? e : "Unexpected error")
    );
  }

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }

  get isPreview() {
    return this.section === "preview";
  }

  handlePreviewQuery(event) {
    this.previewQuery = event.target.value;
  }

  async runPreviewSearch() {
    this.previewLoading = true;
    this.previewResults = [];
    try {
      this.previewResults = await searchAccountsForPreview({
        query: this.previewQuery
      });
    } catch (e) {
      this.toast("Preview search failed", e?.body?.message || e.message, "error");
    } finally {
      this.previewLoading = false;
    }
  }

  handlePreviewAccountPick(event) {
    this.previewAccountId = event.currentTarget.dataset.id;
  }

  handlePreviewRuleChange(event) {
    this.previewRuleId = event.detail.value;
  }

  get previewRuleOptions() {
    return (this.rules || []).map((r) => ({
      label: r.displayLabel || r.ruleId,
      value: r.ruleId
    }));
  }

  async runCommPreview() {
    if (!this.previewAccountId) {
      this.toast("Pick an account", "Search and select an account first.", "warning");
      return;
    }
    this.previewLoading = true;
    try {
      this.previewDto = await previewCareItemComm({
        accountId: this.previewAccountId,
        ruleId: this.previewRuleId
      });
    } catch (e) {
      this.toast("Preview failed", e?.body?.message || e.message, "error");
    } finally {
      this.previewLoading = false;
    }
  }

}
