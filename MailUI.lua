local _, ns = ...
local Mail, L = ns.Mail, ns.L
local Style, T = ns.Style, ns.SettingsTheme
local UI = {}
ns.MailUI = UI
local frame, saved, makeWindow
local hookedSendFrame

function UI.UpdateMailboxButton()
    local button = UI.mailboxButton
    if not button then return end
    button:SetShown(not (SendMailFrame and SendMailFrame:IsShown()))
    local enabled = not InCombatLockdown()
    button:SetEnabled(enabled)
    button.Icon:SetAlpha(enabled and 1 or .38)
end

-- Mail UI may be loaded on demand, after the addon has initialized.
function UI.AttachMailboxButton()
    if not makeWindow or not MailFrame then return end
    if not UI.mailboxButton then
        local button = Style.ProfessionLauncher(MailFrame, "Sintezza_Disenchant_MailboxButton",
            L.MAIL_LAUNCHER, function() UI.Open() end)
        button:SetPoint("TOPRIGHT",MailFrame,"TOPRIGHT",-30,-28)
        UI.mailboxButton=button
    end
    -- Listen to the actual send pane, including tab switches made by addons.
    if SendMailFrame and hookedSendFrame~=SendMailFrame then
        SendMailFrame:HookScript("OnShow",UI.UpdateMailboxButton)
        SendMailFrame:HookScript("OnHide",UI.UpdateMailboxButton)
        hookedSendFrame=SendMailFrame
    end
    UI.UpdateMailboxButton()
end

local launcherEvents=CreateFrame("Frame")
for _,event in ipairs({"ADDON_LOADED","MAIL_SHOW","PLAYER_REGEN_DISABLED","PLAYER_REGEN_ENABLED"}) do
    launcherEvents:RegisterEvent(event)
end
launcherEvents:SetScript("OnEvent",function() UI.AttachMailboxButton() end)

local function Button(parent, text, width)
    local button = Style.Button(parent)
    button:SetSize(width, 24)
    button:SetText(text)
    return button
end

local function Text(parent, text, size, color)
    local label = parent:CreateFontString(nil, "OVERLAY")
    T:Font(label, size, "", color)
    label:SetText(text)
    label:SetJustifyH("LEFT")
    return label
end

function UI.ToggleRecipients()
    if not frame or Mail.busy then return end
    local entries = {}
    for index, address in ipairs(Mail.GetKnownRecipients()) do
        entries[index] = { value = address, label = address }
    end
    if #entries == 0 then
        entries[1] = { label = L.MAIL_NO_KNOWN_CHARS, disabled = true }
    end
    T:OpenPicker(frame.characters, entries, Mail.recipient, function(address)
        if Mail.busy then return end
        frame.recipient:SetText(address)
        frame.recipient:ClearFocus()
        Mail.SetRecipient(address)
    end)
end
function UI.Refresh()
    if not frame then return end
    local busy=Mail.busy
    local count=0
    for _ in pairs(Mail.selected) do count=count+1 end
    frame.summary:SetText(string.format(L.MAIL_SELECTION,count,math.ceil(count/Mail.Limit())))
    frame.status:SetText(Mail.status or "")
    frame.action:SetText(Mail.plan and L.MAIL_SEND_CONFIRM or L.MAIL_REVIEW)
    frame.action:SetEnabled(not busy and Mail.open and count>0)
    frame.refresh:SetEnabled(not busy)
    frame.all:SetEnabled(not busy);frame.none:SetEnabled(not busy)
    if busy then frame.recipient:Disable() else frame.recipient:Enable() end
    frame.characters:SetEnabled(not busy)
    if busy then T:ClosePicker(frame.characters) end
    frame.cancel:SetEnabled(busy or Mail.plan~=nil)
    for i,e in ipairs(Mail.items) do
        local row=frame.rows[i]
        if not row then
            row=CreateFrame("Button",nil,frame.child)
            row:SetSize(500,28)
            row.check = Style.CheckButton(row, 16)
            row.check:SetPoint("LEFT",4,0)
            row.icon=row:CreateTexture(nil,"ARTWORK")
            row.icon:SetSize(20,20);row.icon:SetPoint("LEFT",row.check,"RIGHT",4,0)
            row.iconBorder = T:FrameIcon(row, row.icon)
            row.label=Text(row,"",12)
            row.label:SetPoint("LEFT",row.icon,"RIGHT",8,0)
            row.label:SetPoint("RIGHT",row,"RIGHT",-8,0);row.label:SetWordWrap(false)
            row:SetScript("OnClick",function(self) Mail.ToggleItem(self.item.key) end)
            row.check:SetScript("OnClick",function(self)
                local r=self:GetParent();Mail.ToggleItem(r.item.key)
                self:SetChecked(Mail.selected[r.item.key]==true)
            end)
            row:SetScript("OnEnter",function(self)
                if self.item then GameTooltip:SetOwner(self,"ANCHOR_RIGHT");GameTooltip:SetBagItem(self.item.bag,self.item.slot);GameTooltip:Show() end
            end)
            row:SetScript("OnLeave",function() GameTooltip:Hide() end)
            frame.rows[i]=row
        end
        row.item=e;row:SetPoint("TOPLEFT",0,-(i-1)*30)
        row.icon:SetTexture(e.icon)
        T:PaintItemBorder(row.iconBorder, e.quality)
        row.label:SetText(e.link..(e.count>1 and " x"..e.count or ""))
        row.check:SetChecked(Mail.selected[e.key]==true)
        row.check:SetEnabled(not busy)
        row.check:SetAlpha(busy and .55 or 1)
        row:SetEnabled(not busy);row:Show()
    end
    for i=#Mail.items+1,#frame.rows do frame.rows[i].item=nil;frame.rows[i]:Hide() end
    frame.child:SetHeight(math.max(1,#Mail.items*30))
end
local function Create()
    frame=makeWindow("Sintezza_Disenchant_MailFrame",580,536)
    UI.frame=frame
    frame:SetPoint("CENTER",UIParent,"CENTER",180,0)
    frame.title:SetText(L.MAIL_TITLE);frame.rows={}
    local label=Text(frame,L.MAIL_RECIPIENT,12)
    label:SetPoint("TOPLEFT",18,-60)
    local edit=CreateFrame("EditBox",nil,frame,"BackdropTemplate")
    edit:SetSize(340,24);edit:SetPoint("TOPLEFT",18,-81);edit:SetAutoFocus(false);edit:SetMaxLetters(100)
    edit:EnableMouse(true)
    edit:SetTextInsets(8,8,0,0)
    T:SkinInput(edit, 12)
    frame.recipient=edit
    edit:SetText(Mail.recipient or "")
    edit:SetScript("OnTextChanged",function(self,userInput)
        if userInput then T:ClosePicker(frame.characters);Mail.SetRecipient(self:GetText()) end
    end)
    edit:SetScript("OnEscapePressed",function(self) self:ClearFocus() end)
    frame.characters=Button(frame,L.MAIL_KNOWN_CHARS,170)
    T:DropdownArrow(frame.characters, frame.characters:GetFontString())
    frame.characters:SetPoint("LEFT",edit,"RIGHT",12,0)
    frame.characters:SetScript("OnClick",UI.ToggleRecipients)
    local instructions=Text(frame,L.MAIL_INSTRUCTIONS,11,T.muted)
    instructions:SetPoint("TOPLEFT",18,-116);instructions:SetWidth(540);instructions:SetWordWrap(true)
    frame.summary=Text(frame,"",12)
    frame.summary:SetPoint("TOPLEFT",18,-156)
    local scroll=CreateFrame("ScrollFrame",nil,frame,"BackdropTemplate")
    T:AttachScrollBar(scroll, frame)
    scroll:SetPoint("TOPLEFT",18,-180);scroll:SetPoint("BOTTOMRIGHT",-36,126)
    frame.child=CreateFrame("Frame",nil,scroll);frame.child:SetSize(500,1);scroll:SetScrollChild(frame.child)
    frame.status=Text(frame,"",11,T.muted)
    frame.status:SetPoint("BOTTOMLEFT",18,58);frame.status:SetWidth(540);frame.status:SetWordWrap(true)
    frame.all=Button(frame,L.SELECT_ALL,110);frame.all:SetPoint("BOTTOMLEFT",18,94)
    frame.all:SetScript("OnClick",function() Mail.SelectAll(true) end)
    frame.none=Button(frame,L.CLEAR_SELECTION,120);frame.none:SetPoint("LEFT",frame.all,"RIGHT",8,0)
    frame.none:SetScript("OnClick",function() Mail.SelectAll(false) end)
    frame.refresh=Button(frame,L.REFRESH,100);frame.refresh:SetPoint("LEFT",frame.none,"RIGHT",8,0)
    frame.refresh:SetScript("OnClick",function() Mail.Scan() end)
    frame.action=Button(frame,L.MAIL_REVIEW,190);frame.action:SetPoint("BOTTOMRIGHT",-18,18)
    frame.action.primary = true
    Style.PaintButton(frame.action)
    frame.action:SetScript("OnClick",function()
        edit:ClearFocus()
        if Mail.plan then Mail.Confirm() else Mail.Prepare() end
        UI.Refresh()
    end)
    frame.cancel=Button(frame,L.MAIL_CANCEL,140);frame.cancel:SetPoint("RIGHT",frame.action,"LEFT",-8,0)
    frame.cancel:SetScript("OnClick",function() Mail.Stop() end)
    frame:HookScript("OnHide",function() T:ClosePicker(frame.characters);if Mail.busy then Mail.Stop() end;Mail.plan=nil end)
    frame:Hide()
end
function UI.Init(db,windowFactory)
    saved,makeWindow=db,windowFactory
    Mail.Init(saved)
    Mail.onChange=UI.Refresh
    Mail.onClose=function() if frame then frame:Hide() end end
    UI.AttachMailboxButton()
end
function UI.Open()
    if not Mail.open or InCombatLockdown() then
        DEFAULT_CHAT_FRAME:AddMessage("Sintezza Disenchant: "..L.MAIL_NEED_BOX)
        return
    end
    if not frame then Create() end
    if not frame:IsShown() then Mail.Scan();frame:Show() end
    UI.Refresh()
end
function UI.Toggle()
    if frame and frame:IsShown() then frame:Hide() else UI.Open() end
end
