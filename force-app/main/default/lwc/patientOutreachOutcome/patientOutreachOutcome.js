import { LightningElement, api, wire } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { refreshApex } from "@salesforce/apex";
import { getObjectInfo, getPicklistValues } from "lightning/uiObjectInfoApi";
import ACCOUNT_OBJECT from "@salesforce/schema/Account";
import INACTIVE_REASONS_FIELD from "@salesforce/schema/Account.Inactive_Reasons__c";
import {
  publish,
  subscribe,
  unsubscribe,
  MessageContext,
  APPLICATION_SCOPE
} from "lightning/messageService";
import PatientOutreachState from "@salesforce/messageChannel/PatientOutreachState__c";
import getPatientWorkspace from "@salesforce/apex/OutreachWorkbenchController.getPatientWorkspace";
import logOutcome from "@salesforce/apex/OutreachWorkbenchController.logOutcome";
import getCatalog from "@salesforce/apex/OutreachOutcomeCatalog.getCatalog";
import getRecentComments from "@salesforce/apex/OutreachWorkbenchController.getRecentComments";

const OUTCOMES = [
  "No Answer",
  "Left Message",
  "Needs Call Back",
  "Unable to Reach",
  "Awaiting Patient Callback",
  "Awaiting Patient Response",
  "Appointment Scheduled",
  "Patient Refused Scheduling",
  "Escalated for Service Recovery",
  "Inactive Patient",
  "Patient Deceased"
];

const TERMINAL_OUTCOMES = new Set([
  "Appointment Scheduled",
  "Patient Refused Scheduling",
  "Inactive Patient",
  "Patient Deceased"
]);

const INACTIVE_REASON_FALLBACK = [
  "18 Month Inactive",
  "Attend same PCP as family / significant other",
  "Care Coordination Concerns (prescriptions / referrals)",
  "Communication Issue",
  "Continuity of Care (patient mid-treatment)",
  "Cost Concerns",
  "Declined Membership",
  "Distance from Clinic",
  "Distance to the Clinic/ No Ride",
  "Insurance Coverage",
  "Issue with Prescription",
  "Moved",
  "Only wants MD / Unable to schedule with MD",
  "Other",
  "PCP comes to patient (home health / senior living)",
  "Prefers MD",
  "Provider Experiences",
  "Provider Leaving",
  "Returned to Previous Provider",
  "Satisfied with current PCP",
  "Service Offering",
  "Umbrella Network / Referrals",
  "Unknown/ Patient Refused to Give Reason",
  "Visit Experience"
];

export default class PatientOutreachOutcome extends LightningElement {
  recentComments = [];
  showAllComments = false;
  @api recordId;
  workspace;
  workspaceWire;
  error;
  isLoading = true;
  outcome = "Left Message";
  channel = "Phone";
  keepWorking = false;
  catalog = null;
  detail = "";
  snoozeUntil;
  showSnoozeDialog = false;
  closeRelated = false;
  selectedNeedIds = [];
  acknowledgedNeedIds = [];
  inactiveReason;
  inactiveReasonOptions = INACTIVE_REASON_FALLBACK.map((value) => ({
    label: value,
    value
  }));
  confirmDeceased = false;
  accountRecordTypeId;
  subscription = null;
  stateReceived = false;
  stateRequested = false;

  @wire(MessageContext) messageContext;

  renderedCallback() {
    this.subscribeToChannel();
    if (
      this.messageContext &&
      this.recordId &&
      !this.stateReceived &&
      !this.stateRequested
    ) {
      this.stateRequested = true;
      this.requestNeedState();
    }
  }

  disconnectedCallback() {
    this.unsubscribeFromChannel();
  }

  @wire(getObjectInfo, { objectApiName: ACCOUNT_OBJECT })
  wiredAccountInfo({ data }) {
    if (data) this.accountRecordTypeId = data.defaultRecordTypeId;
  }

  @wire(getPicklistValues, {
    recordTypeId: "$accountRecordTypeId",
    fieldApiName: INACTIVE_REASONS_FIELD
  })
  wiredInactiveReasons({ data }) {
    if (!data?.values?.length) return;
    this.inactiveReasonOptions = data.values.map((v) => ({
      label: v.label,
      value: v.value
    }));
  }

  @wire(getPatientWorkspace, { recordId: "$recordId" })
  wiredWorkspace(result) {
    this.workspaceWire = result;
    if (result.data !== undefined) {
      this.workspace = result.data || null;
      this.error = undefined;
      this.isLoading = false;
      this.loadRecentComments();
      this.closeRelated = TERMINAL_OUTCOMES.has(this.outcome);
      if (!this.stateReceived) {
        this.bootstrapSelectedNeeds();
        this.requestNeedState();
      }
    } else if (result.error) {
      this.error = this.message(
        result.error,
        "Unable to load outreach workspace."
      );
      this.isLoading = false;
    }
  }

  get hasWorkspace() {
    return !!this.workspace;
  }
  get activeNeeds() {
    return (this.workspace?.needs || []).filter(
      (n) =>
        n.state !== "Superseded" &&
        n.state !== "Shadow" &&
        n.state !== "Silenced"
    );
  }

  @wire(getCatalog)
  wiredCatalog({ data, error }) {
    if (data) {
      this.catalog = data;
    } else if (error) {
      // Fall back to hardcoded OUTCOMES / CHANNELS
      this.catalog = null;
    }
  }

  get outcomeOptions() {
    const rows = this.catalog?.callResults;
    if (rows && rows.length) {
      return rows.map((r) => ({ label: r.label, value: r.label }));
    }
    return OUTCOMES.map((value) => ({ label: value, value }));
  }
  get channelOptions() {
    const rows = this.catalog?.channels;
    if (rows && rows.length) {
      return rows.map((r) => ({ label: r.label, value: r.label }));
    }
    return [
      { label: "Phone", value: "Phone" },
      { label: "SMS", value: "SMS" },
      { label: "Email", value: "Email" },
      { label: "Portal", value: "Portal" }
    ];
  }
  get isSnoozedOutcome() {
    return this.outcome === "Snoozed";
  }
  get isCommentOnlyMode() {
    return !!this.workspace?.commentOnlyMode;
  }
  get cooldownBanner() {
    return this.workspace?.cooldownMessage || "";
  }
  get outcomeSectionLabel() {
    return this.isCommentOnlyMode ? "Comment only" : "Log Outcome";
  }
  get showInactiveReason() {
    return this.outcome === "Inactive Patient";
  }
  get showDeceasedConfirm() {
    return this.outcome === "Patient Deceased";
  }
  get selectedNeedCount() {
    return this.selectedNeedIds.length;
  }
  get isSnoozeDisabled() {
    return (
      this.isLoading ||
      this.isCommentOnlyMode ||
      this.selectedNeedCount === 0
    );
  }
  get selectionHint() {
    if (this.isCommentOnlyMode) {
      return "Status changes are locked today — comments only.";
    }
    return `${this.selectedNeedCount} care item(s) selected from Actions & Care Gaps.`;
  }
  get selectedCareItemLabels() {
    const ids = new Set(this.selectedNeedIds || []);
    return (this.activeNeeds || [])
      .filter((n) => ids.has(n.id))
      .map((n) => n.displayLabel || n.needType || "Care item");
  }
  get snoozeConfirmSummary() {
    const labels = this.selectedCareItemLabels;
    if (!labels.length) return "No care items selected.";
    return labels.join(", ");
  }
  get snoozePresetOptions() {
    return [
      { label: "1 week", days: 7 },
      { label: "2 weeks", days: 14 },
      { label: "3 weeks", days: 21 }
    ];
  }

  bootstrapSelectedNeeds() {
    this.selectedNeedIds = this.activeNeeds.map((n) => n.id);
    this.acknowledgedNeedIds = [];
  }

  subscribeToChannel() {
    if (this.subscription || !this.messageContext) return;
    this._messageContext = this.messageContext;
    this.subscription = subscribe(
      this.messageContext,
      PatientOutreachState,
      (message) => this.handleMessage(message),
      { scope: APPLICATION_SCOPE }
    );
  }
  unsubscribeFromChannel() {
    if (this.subscription) {
      unsubscribe(this.subscription);
      this.subscription = null;
    }
  }
  handleMessage(message) {
    if (!message || message.recordId !== this.recordId) return;
    if (message.eventType === "NEED_STATE") {
      this.stateReceived = true;
      try {
        this.selectedNeedIds = JSON.parse(message.selectedNeedIdsJson || "[]");
      } catch (e) {
        this.selectedNeedIds = [];
      }
      try {
        this.acknowledgedNeedIds = JSON.parse(
          message.acknowledgedNeedIdsJson || "[]"
        );
      } catch (e) {
        this.acknowledgedNeedIds = [];
      }
    } else if (message.eventType === "REFRESH") {
      refreshApex(this.workspaceWire);
    }
  }
  requestNeedState() {
    const ctx = this._messageContext || this.messageContext;
    if (!ctx || !this.recordId) return;
    try {
      publish(ctx, PatientOutreachState, {
        eventType: "REQUEST_STATE",
        recordId: this.recordId
      });
    } catch (e) {
      // ignore
    }
  }
  publishRefresh() {
    const ctx = this._messageContext || this.messageContext;
    if (!ctx || !this.recordId) return;
    try {
      publish(ctx, PatientOutreachState, {
        eventType: "REFRESH",
        recordId: this.recordId
      });
    } catch (e) {
      // ignore
    }
  }

  handleOutcomeChange(event) {
    this.outcome = event.detail.value;
    if (this.outcome !== "Inactive Patient") this.inactiveReason = null;
    if (this.outcome !== "Patient Deceased") this.confirmDeceased = false;
    this.closeRelated = TERMINAL_OUTCOMES.has(this.outcome);
  }
  datePlusDays(days) {
    const d = new Date();
    d.setDate(d.getDate() + days);
    const yyyy = d.getFullYear();
    const mm = String(d.getMonth() + 1).padStart(2, "0");
    const dd = String(d.getDate()).padStart(2, "0");
    return `${yyyy}-${mm}-${dd}`;
  }
  handleSnoozePreset(event) {
    const days = Number(event.currentTarget.dataset.days);
    if (!Number.isFinite(days)) return;
    this.snoozeUntil = this.datePlusDays(days);
  }
  handleChannelChange(event) {
    this.channel = event.detail.value;
  }
  handleDetailChange(event) {
    this.detail = event.detail.value;
  }
  handleSnoozeUntil(event) {
    this.snoozeUntil = event.detail.value;
  }
  handleInactiveReason(event) {
    this.inactiveReason = event.detail.value;
  }
  handleConfirmDeceased(event) {
    this.confirmDeceased = event.target.checked;
  }

  openSnoozeDialog() {
    if (this.isCommentOnlyMode) {
      this.toast(
        "Locked today",
        "Status changes are locked — comments only.",
        "error"
      );
      return;
    }
    if (this.selectedNeedCount === 0) {
      this.toast(
        "Select care items",
        "Choose which care items to snooze in Actions & Care Gaps.",
        "error"
      );
      return;
    }
    if (!this.snoozeUntil) this.snoozeUntil = this.datePlusDays(21);
    this.showSnoozeDialog = true;
  }
  cancelSnoozeDialog() {
    this.showSnoozeDialog = false;
  }
  async confirmSnoozeAndSave() {
    if (!this.snoozeUntil) {
      this.toast("Snooze date required", "Pick a wake-up date.", "error");
      return;
    }
    if (this.selectedNeedCount === 0) {
      this.toast(
        "Select care items",
        "Choose which care items to snooze in Actions & Care Gaps.",
        "error"
      );
      return;
    }
    this.showSnoozeDialog = false;
    this.outcome = "Snoozed";
    this.closeRelated = false;
    await this.saveOutcome();
  }


  handleKeepWorking(event) {
    this.keepWorking = event.target.checked;
  }

  async saveOutcome() {
    if (!this.workspace?.episodeId) return;

    const commentOnly = this.isCommentOnlyMode;
    if (commentOnly) {
      if (!(this.detail || "").trim()) {
        this.toast(
          "Comment required",
          "Add a comment — status changes are locked today.",
          "error"
        );
        return;
      }
    } else {
      if (this.showInactiveReason && !this.inactiveReason) {
        this.toast(
          "Inactive reason required",
          "Select why the patient is inactive before saving.",
          "error"
        );
        return;
      }
      if (this.showDeceasedConfirm && !this.confirmDeceased) {
        this.toast(
          "Confirmation required",
          "Confirm the patient is deceased before saving.",
          "error"
        );
        return;
      }
      for (const need of this.activeNeeds) {
        if (
          this.selectedNeedIds.includes(need.id) &&
          need.forceAcknowledge &&
          !this.acknowledgedNeedIds.includes(need.id)
        ) {
          this.toast(
            "Confirmation required",
            `Confirm that "${need.displayLabel || need.needType}" was addressed.`,
            "error"
          );
          return;
        }
      }
    }

    this.isLoading = true;
    try {
      this.workspace = await logOutcome({
        episodeId: this.workspace.episodeId,
        outcome: this.outcome,
        channel: this.channel,
        detail: this.detail,
        snoozeUntil: this.snoozeUntil || null,
        closeRelated: commentOnly ? false : this.closeRelated,
        selectedNeedIds: commentOnly ? [] : this.selectedNeedIds,
        acknowledgedNeedIds: commentOnly ? [] : this.acknowledgedNeedIds,
        caseStatus: null,
        disposition: null,
        inactiveReason: commentOnly ? null : this.inactiveReason || null,
        commentOnly,
        keepWorking: this.keepWorking === true
      });
      await this.loadRecentComments();
      this.toast(
        commentOnly ? "Comment saved" : "Outcome logged",
        commentOnly
          ? "Comment saved. Outcomes stay locked until tomorrow."
          : "Outreach outcome saved.",
        "success"
      );
      this.detail = "";
      this.inactiveReason = null;
      this.confirmDeceased = false;
      this.stateReceived = false;
      this.stateRequested = false;
      this.bootstrapSelectedNeeds();
      await refreshApex(this.workspaceWire);
      this.publishRefresh();
      this.requestNeedState();
    } catch (e) {
      this.showError(
        e,
        commentOnly ? "Unable to save comment." : "Unable to log outcome."
      );
    } finally {
      this.isLoading = false;
    }
  }

  message(error, fallback) {
    return error?.body?.message || error?.message || fallback;
  }
  showError(error, fallback) {
    this.error = this.message(error, fallback);
    this.toast("Outreach", this.error, "error");
  }

  async loadRecentComments() {
    if (!this.recordId) {
      this.recentComments = [];
      return;
    }
    try {
      this.recentComments =
        (await getRecentComments({ recordId: this.recordId, rowLimit: 20 })) ||
        [];
    } catch (e) {
      this.recentComments = [];
    }
  }
  get visibleComments() {
    const all = this.recentComments || [];
    if (this.showAllComments) return all.map((c) => this.decorateComment(c));
    return all.slice(0, 5).map((c) => this.decorateComment(c));
  }
  get hasRecentComments() {
    return (this.recentComments || []).length > 0;
  }
  get hasMoreComments() {
    return (this.recentComments || []).length > 5 && !this.showAllComments;
  }
  get hiddenCommentCount() {
    return Math.max(0, (this.recentComments || []).length - 5);
  }
  decorateComment(c) {
    const when = c.eventAt
      ? new Date(c.eventAt).toLocaleString(undefined, {
          month: "short",
          day: "numeric",
          hour: "numeric",
          minute: "2-digit"
        })
      : "";
    return {
      ...c,
      whenLabel: when,
      metaLabel: [c.careItemLabel, c.outcome || c.eventType, c.actorName]
        .filter(Boolean)
        .join(" · ")
    };
  }
  expandComments() {
    this.showAllComments = true;
  }

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }
}