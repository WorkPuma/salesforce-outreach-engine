import { LightningElement } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getQueueDashboard from "@salesforce/apex/OutreachQueueService.getQueueDashboard";
import openUnclaimedEpisode from "@salesforce/apex/OutreachWorkbenchController.openUnclaimedEpisode";
import recordSoftHold from "@salesforce/apex/OutreachWorkbenchController.recordSoftHold";

const PREVIEW_LIMIT = 8;
const REFRESH_INTERVAL_MS = 120000;
const MIN_REFRESH_GAP_MS = 20000;
const MONTHS = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec"
];

export default class OutreachWorkbench extends NavigationMixin(
  LightningElement
) {
  priorityFilter = "All";
  supervisorMode = false;
  canSupervise = false;
  omniEnabled = false;
  kpis = [];
  priorityLoad = {
    urgentCount: 0,
    routineCount: 0,
    statCount: 0,
    totalCount: 0,
    percentUrgent: 0
  };
  recentlyWorked = [];
  unclaimed = [];
  showAllUnclaimed = false;
  error;
  isLoading = true;
  _refreshTimer;
  _refreshInFlight = false;
  _refreshPromise;
  _lastFetchAt = 0;
  _onVisibilityChange;

  get priorityOptions() {
    return [
      { label: "All priorities", value: "All" },
      { label: "STAT", value: "STAT" },
      { label: "Urgent", value: "Urgent" },
      { label: "Routine", value: "Routine" }
    ];
  }
  get modeOptions() {
    return [
      { label: "My queue", value: "agent" },
      { label: "Supervisor (all)", value: "supervisor" }
    ];
  }
  get modeValue() {
    return this.supervisorMode ? "supervisor" : "agent";
  }
  get hasWorked() {
    return this.recentlyWorked.length > 0;
  }
  get hasUnclaimed() {
    return this.unclaimed.length > 0;
  }
  get hasMoreUnclaimed() {
    return this.unclaimed.length > PREVIEW_LIMIT && !this.showAllUnclaimed;
  }
  get visibleUnclaimed() {
    if (this.showAllUnclaimed) return this.unclaimed;
    return this.unclaimed.slice(0, PREVIEW_LIMIT);
  }
  get priorityPercentLabel() {
    return `${this.priorityLoad?.percentUrgent || 0}%`;
  }
  get donutStyle() {
    const pct = this.priorityLoad?.percentUrgent || 0;
    const deg = Math.round((pct / 100) * 360);
    return `--ow-urgent-deg: ${deg}deg;`;
  }

  connectedCallback() {
    this.loadDashboard({ showSpinner: true });
    this._onVisibilityChange = () => {
      if (document.visibilityState === "visible") {
        this.loadDashboard({ showSpinner: false });
      }
    };
    document.addEventListener("visibilitychange", this._onVisibilityChange);
    this._refreshTimer = setInterval(() => {
      if (document.visibilityState === "hidden") return;
      this.loadDashboard({ showSpinner: false });
    }, REFRESH_INTERVAL_MS);
  }

  disconnectedCallback() {
    if (this._refreshTimer) {
      clearInterval(this._refreshTimer);
      this._refreshTimer = undefined;
    }
    if (this._onVisibilityChange) {
      document.removeEventListener(
        "visibilitychange",
        this._onVisibilityChange
      );
      this._onVisibilityChange = undefined;
    }
  }

  async loadDashboard({ showSpinner = true } = {}) {
    if (
      !showSpinner &&
      this._lastFetchAt &&
      Date.now() - this._lastFetchAt < MIN_REFRESH_GAP_MS
    ) {
      return;
    }
    if (this._refreshInFlight) {
      if (!showSpinner) return;
      try {
        await this._refreshPromise;
      } catch (_) {
        // prior refresh failed; continue with a hard reload
      }
    }
    if (this._refreshInFlight) return;
    this._refreshInFlight = true;
    if (showSpinner) this.isLoading = true;
    this.error = undefined;
    this._refreshPromise = this._fetchDashboard(showSpinner);
    try {
      await this._refreshPromise;
    } finally {
      this._refreshInFlight = false;
      this._refreshPromise = undefined;
      if (showSpinner) this.isLoading = false;
    }
  }

  async _fetchDashboard(showSpinner) {
    try {
      const d = await getQueueDashboard({
        supervisorMode: this.supervisorMode,
        priorityFilter: this.priorityFilter,
        rowLimit: 40
      });
      this.canSupervise = d.canSupervise === true;
      this.supervisorMode = d.supervisorMode === true;
      this.omniEnabled = d.omniEnabled === true;
      this.kpis = (d.kpis || []).map((k) => ({
        ...k,
        label: (k.label || k.key || "").toUpperCase()
      }));
      this.priorityLoad = d.priorityLoad || {
        urgentCount: 0,
        routineCount: 0,
        statCount: 0,
        totalCount: 0,
        percentUrgent: 0
      };
      this.recentlyWorked = this.mapWorked(d.recentlyWorked || []);
      this.unclaimed = this.mapUnclaimed(d.unclaimed || []);
      this._lastFetchAt = Date.now();
      if (showSpinner) this.showAllUnclaimed = false;
    } catch (error) {
      this.kpis = [];
      this.priorityLoad = {
        urgentCount: 0,
        routineCount: 0,
        statCount: 0,
        totalCount: 0,
        percentUrgent: 0
      };
      this.recentlyWorked = [];
      this.unclaimed = [];
      this.error = this.message(error, "Unable to load the outreach queue.");
    }
  }

  mapWorked(rows) {
    return rows.map((row) => ({
      ...row,
      statusClass: this.statusClass(row.status)
    }));
  }

  mapUnclaimed(rows) {
    return rows.map((row) => ({
      ...row,
      priorityLabel: this.priorityLabel(row.priority),
      priorityClass: this.priorityClass(row.priority),
      gapBadges: this.gapBadges(row.careGaps),
      dueDateLabel: this.formatDue(row.dueDate)
    }));
  }

  statusClass(status) {
    const s = (status || "").toLowerCase();
    if (s === "snoozed") return "ow-status ow-status_snoozed";
    if (s === "claimed") return "ow-status ow-status_claimed";
    return "ow-status";
  }

  priorityLabel(priority) {
    if (priority === "Urgent") return "! Urgent";
    if (priority === "STAT") return "! STAT";
    return priority || "Routine";
  }

  priorityClass(priority) {
    if (priority === "Urgent") return "ow-priority ow-priority_urgent";
    if (priority === "STAT") return "ow-priority ow-priority_stat";
    return "ow-priority ow-priority_routine";
  }

  gapBadges(careGaps) {
    const gaps = Array.isArray(careGaps) ? careGaps : [];
    if (gaps.length === 0) return [];
    if (gaps.length > 1) {
      return [
        {
          key: "MULTI",
          label: "Multiple Gaps",
          className: "ow-gap ow-gap_multi"
        }
      ];
    }
    const g = gaps[0];
    return [
      {
        key: g.key || g.label,
        label: g.label,
        className: this.gapClass(g.key)
      }
    ];
  }

  gapClass(key) {
    if (key === "AWV") return "ow-gap ow-gap_awv";
    if (key === "OFF_CADENCE") return "ow-gap ow-gap_off";
    if (key === "NO_NEXT") return "ow-gap ow-gap_default";
    if (
      key === "URGENT_REFERRAL" ||
      key === "MDDO" ||
      key === "DISCHARGE_TCM" ||
      key === "ADMISSION_TOUCHBASE"
    )
      return "ow-gap ow-gap_default";
    return "ow-gap ow-gap_default";
  }

  formatDue(value) {
    if (!value) return "";
    const d = new Date(value);
    if (Number.isNaN(d.getTime())) return String(value);
    return `${MONTHS[d.getUTCMonth()]} ${String(d.getUTCDate()).padStart(
      2,
      "0"
    )}, ${d.getUTCFullYear()}`;
  }

  handlePriorityChange(event) {
    this.priorityFilter = event.detail.value;
    this.loadDashboard();
  }
  handleModeChange(event) {
    this.supervisorMode = event.detail.value === "supervisor";
    this.loadDashboard();
  }
  handleRefresh() {
    this.loadDashboard();
  }
  handleViewAll() {
    this.showAllUnclaimed = true;
  }

  async handleOpenClick(event) {
    const el = event.currentTarget;
    const row = {
      accountId: el.dataset.accountId,
      episodeId: el.dataset.episodeId,
      status: el.dataset.status
    };
    if (row.status === "Unclaimed") {
      await this.openUnclaimed(row);
      return;
    }
    await this.openPatient(row.accountId, row.episodeId);
  }

  async openUnclaimed(row) {
    this.isLoading = true;
    try {
      const claimed = await openUnclaimedEpisode({
        episodeId: row.episodeId,
        priorityFilter: this.priorityFilter
      });
      if (!claimed?.patientId) {
        this.toast(
          "No work available",
          "No unclaimed patients match this priority.",
          "info"
        );
        await this.loadDashboard();
        return;
      }
      if (claimed.episodeId !== row.episodeId) {
        this.toast(
          "Already taken",
          "That patient was claimed by someone else. Opening the next available patient.",
          "info"
        );
      }
      await this.openPatient(claimed.patientId, claimed.episodeId);
      await this.loadDashboard();
    } catch (error) {
      this.showError(error, "Unable to open patient.");
      await this.loadDashboard();
    } finally {
      this.isLoading = false;
    }
  }

  async openPatient(accountId) {
    if (!accountId) return;
    try {
      await recordSoftHold({ recordId: accountId });
    } catch (e) {
      // Soft-hold is best-effort; still navigate.
    }
    this[NavigationMixin.Navigate]({
      type: "standard__recordPage",
      attributes: {
        recordId: accountId,
        objectApiName: "Account",
        actionName: "view"
      }
    });
  }

  message(error, fallback) {
    return error?.body?.message || error?.message || fallback;
  }
  showError(error, fallback) {
    this.error = this.message(error, fallback);
    this.toast("Outreach error", this.error, "error");
  }
  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }
}