#####################################################
# HelloID-Conn-SA-Sync-Exchange-Online-Groups-To-SelfService-Products
#
# Version: 3.0.0
#####################################################
$VerbosePreference = "SilentlyContinue"
$informationPreference = "Continue"
$WarningPreference = "Continue"

# Set TLS to accept TLS, TLS 1.1 and TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12

######################################################################################
# Connection Configuration - Set up connection credentials
######################################################################################
# HelloID API connection (required)
$helloIDPortalBaseUrl = $portalBaseUrl # When running from HelloID, set from default Global Variable
$helloIDPortalApiKey = $portalApiKey # When running from HelloID, set from default Global Variable
$helloIDPortalApiSecret = $portalApiSecret # When running from HelloID, set from default Global Variable

# Exchange Online connection (required)
# $EntraIdOrganization = "" # Set from Global Variable
# $EntraIdAppId = "" # Set from Global Variable
# $EntraIdCertificateBase64String = "" # Set from Global Variable
# $EntraIdCertificatePassword = "" # Set from Global Variable
######################################################################################

######################################################################################
# Script Behavior - Change only when testing/troubleshooting
######################################################################################
$dryRun = $false  # If $true, shows what would happen without making changes
$verboseLogging = $false  # If $true, logs every action (generates lots of log data)

# Test run settings - Limit operations per type (useful for testing)
# NOTE: All groups are retrieved for correct comparison, but operations are limited per type
$testRun = $true  # If $true, limits operations based on the max values below
$testRunMaxCreates = 1 # Maximum products to CREATE in test run (0 = no creates)
$testRunMaxUpdates = 1 # Maximum products to UPDATE in test run (0 = no updates)
$testRunMaxDeletes = 1 # Maximum products to DELETE in test run (0 = no deletes)
######################################################################################

######################################################################################
# Product Lifecycle - Safety thresholds and removal behavior
######################################################################################
# Create Threshold - Maximum number of NEW products to create in one run
# This is a safety limit to prevent accidental mass creation
# Set to $null for unlimited (not recommended)
$createThreshold = 10

# Update Threshold - Maximum number of EXISTING products to update in one run
# This is a safety limit to prevent accidental mass updates
# Set to $null for unlimited (not recommended)
# Note: Only applies when $overwriteExistingProduct = $true
$updateThreshold = 10

# Remove Threshold - Maximum number of products to disable/remove in one run
# This is a critical safety limit to prevent accidental mass deletion/disabling
# Set to $null for unlimited (NOT RECOMMENDED - very dangerous)
$removeThreshold = 10

# Remove Behavior - What happens when a product no longer exists in the source system
# Options:
# - "None": Keep products even when they no longer exist in source (safest - requires manual cleanup)
# - "Disable": Disable products when they no longer exist (reversible - recommended)
# - "Remove": Permanently delete products when they no longer exist (IRREVERSIBLE - use with caution)
# 
# WARNING: "Remove" permanently deletes products and cannot be undone. All product history is lost.
#          Make sure you have backups and are certain before using this option.
$removeProductBehavior = "Remove"  # Options: "None", "Disable", "Remove"

# Remove Resource Owner Group when product is removed
# Only applies when $removeProductBehavior = "Remove" (not when "Disable")
# Only removes Local groups (AzureAD groups are never removed)
# WARNING: This permanently deletes the resource owner group along with the product
# - If $true: When a product is removed, its resource owner group is also deleted (recommended for "Calculated" mode)
# - If $false: Resource owner groups are preserved even when products are removed (requires manual cleanup)
# Recommendation: Set to $true for "Calculated" mode to avoid orphaned groups, $false for "Fixed" mode
$removeResourceOwnerGroupWithProduct = $true
######################################################################################

######################################################################################
# Source Data Selection - Which groups to sync
######################################################################################
# PowerShell commands to import (only change if needed)
$commands = @("Get-User", "Get-DistributionGroup")

# Group Properties to Retrieve
# REQUIRED: "Guid" (unique identifier) and "DisplayName" (used in product/group names)
# Common: Guid, DisplayName, PrimarySmtpAddress, Alias, ManagedBy, CustomAttribute1-15, etc.
# Full list: https://learn.microsoft.com/en-us/powershell/module/exchange/get-distributiongroup
$exchangeOnlineGroupPropertiesToRetrieve = @(
    "Guid" # REQUIRED: (unique identifier)
    "Id"
    "Identity"
    "Alias"
    "Name"
    "DisplayName"
    "PrimarySmtpAddress"
    "RecipientType"
    "RecipientTypeDetails"
)

# Filter which groups to sync (optional)
# Examples:
# - All groups: $null
# - By DisplayName: "DisplayName -like 'DistributionGroup*'"
# - By CustomAttribute: "CustomAttribute15 -eq 'HelloID'"
#   (Recommended: Use a CustomAttribute to control which groups are synced. This allows you to
#    dynamically add/remove groups from the sync without changing the script configuration.)
$exchangeOnlineGroupsFilter = $null
######################################################################################

######################################################################################
# Product Identification - Prefix and unique property
######################################################################################
# Product Identifier Prefix - Used in Code template, action scripts, and filtering
#
# IMPORTANT: HelloID normalizes all product codes by removing dashes and converting to UPPERCASE
# The prefix MUST match HelloID's normalized format for filtering/matching to work correctly
#
# REQUIREMENTS:
# - UPPERCASE only (no lowercase)
# - NO dashes (they're removed by HelloID anyway)
# - Maximum 8 characters (HelloID limit: 40 chars total, GUID without dashes: 32 chars)
$productIdentifierPrefix = "EXOGRP"

# Unique Property - Source object property used to uniquely identify objects
# Typically "GUID" - must match a property retrieved from the source system
# Examples: "GUID" (Exchange groups), "ObjectGuid" (AD groups), "Id" (Entra ID groups)
$sourceObjectUniqueProperty = "GUID"
######################################################################################

######################################################################################
# Product Configuration Function - Defines the complete structure and properties of products
######################################################################################
# This function generates the product configuration for a source object (group/AD group/Entra ID group)
# Configure all product properties here - this is called once per source object during sync
function New-HelloIDProductConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        $SourceObject,
        
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ProductIdentifierPrefix,
        
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceObjectUniqueProperty
    )
    
    return @{
        # ===== IDENTIFICATION & NAMING =====
        # These properties define how products are identified and displayed
            
        # Source Identifier - Unique identifier for products managed by this sync
        # This is typically the same as the Code to create unique identifiers per source object
        # Uses direct PowerShell syntax with variables and source object properties
        # Result: "EXOGRP-12345678-1234-1234-1234-123456789012"
        SourceIdentifier           = "$ProductIdentifierPrefix-$($SourceObject.$SourceObjectUniqueProperty)"

        # Product Code - The unique identifier for each product in HelloID
        # This is automatically processed: dashes removed and converted to UPPERCASE
        # 
        # IMPORTANT NOTES:
        # - Dashes (-) are automatically removed from the final code by HelloID
        # - All characters are automatically converted to UPPERCASE by HelloID
        # - The $ProductIdentifierPrefix is used in action scripts to extract the source object identifier
        # - Action scripts use: [Guid]::New(($product.code.replace("$ProductIdentifierPrefix","")))
        # Result after processing: "EXOGRP12345678123412341234123456789012"
        Code                       = "$ProductIdentifierPrefix-$($SourceObject.$SourceObjectUniqueProperty)"

        # Product Name - The display name shown to users
        # Uses direct access to source object properties
        # Example: "Group Sales Team"
        Name                       = "Exchange Online Group $($SourceObject.DisplayName)"
            
        # Product Description - Detailed description shown to users
        # Can include any source object property in the description
        # Example: "Access to the Exchange Online group: sales@domain.com"
        Description                = "Access to the Exchange Online group: $($SourceObject.PrimarySmtpAddress)"
    
        # ===== VISIBILITY & ACCESS =====
        # Control who can see and request these products
    
        # Visibility - Who can see the product in the catalog
        # Options:
        # - "All": Everyone can see the product (most common)
        # - "ResourceOwnerAndManager": Only resource owners and managers can see it
        # - "ResourceOwner": Only resource owners can see it  
        # - "Disabled": Product is hidden from everyone (but still exists)
        Visibility                 = "Disabled"
    
        # Access Groups - Groups whose members can see AND request these products
        # Format: @("source/groupname", "source/groupname")
        # - Source can be: "local" (HelloID groups) or "AzureAD" (synced from Azure AD)
        # - Use @("local/Users") to give all users access (true self-service)
        # - Use @() (empty array) to limit access to only resource owner/manager
        # - Use @("AzureAD/IT Department", "local/Administrators") for specific groups
        #
        # IMPORTANT: Each user with access to a product takes a HelloID license!
        # Best practice: Start with @("local/Users") for full self-service
        # Alternative: Use @() initially to limit visibility and control licensing costs
        AccessGroups               = @("Local/Users")
    
        # ===== REQUEST SETTINGS =====
        # How users can request these products
    
        # Request Comment - Whether users can/must provide comments when requesting
        # Options:
        # - "Optional": Users can optionally add a comment
        # - "Hidden": No comment field is shown
        # - "Required": Users must provide a comment to request
        RequestCommentOption       = "Optional"
    
        # Allow Multiple Requests - Can a user request the same product multiple times?
        # - $false: User can only have one instance of this product (recommended)
        # - $true: User can request and own multiple instances
        AllowMultipleRequests      = $false
    
        # ===== APPROVAL & WORKFLOW =====
        # Control how requests are approved
    
        # Approval Workflow ID - GUID of the approval workflow to use (optional)
        # How to find: Go to HelloID portal > Self Service > Approval Workflows > Click workflow
        # URL will show: .../approvalworkflow/edit?approvalWorkflowGuid=<THE-GUID-YOU-NEED>
        # 
        # Options:
        # - $null: Uses the default approval workflow configured in HelloID
        # - "12345678-1234-1234-1234-123456789abc": Uses specific workflow by GUID
        #
        # NOTE: Script cannot validate if workflow exists (no API available)
        #       Invalid GUIDs will cause products to use the default workflow
        #       Non-existent GUIDs will cause an error when creatiing products
        ApprovalWorkflowId         = $null
    
        # ===== APPEARANCE =====
        # Visual appearance of the product in HelloID
    
        # Icon Type Selection - Choose between Font Awesome icon or custom icon
        # - $true: Use Font Awesome icon (specify in FaIcon property below)
        # - $false: Use custom icon hash (specify in Icon property below)
        # Most organizations use Font Awesome icons ($true) as they're easier to configure
        UseFaIcon                  = $true
    
        # Font Awesome Icon - Icon shown with the product (only used if UseFaIcon = $true)
        # Specify WITHOUT 'fa-' prefix - it will be added automatically
        # Browse icons at: https://fontawesome.com/v5/search?m=free
        # Common examples: "address-book", "users", "envelope", "folder", "briefcase", "building"
        # Invalid icon names result in no icon being shown (no error occurs)
        FaIcon                     = "address-book"
    
        # Custom Icon Hash - Custom icon identifier (only used if UseFaIcon = $false)
        # This is a hash/GUID of a custom icon uploaded to HelloID
        # Example: "824D1F9AA5CCD3978535A6455B2186B5"
        # Leave as $null when using Font Awesome icons
        Icon                       = $null
    
        # ===== CATEGORY =====
        # Category for organizing products in the catalog
    
        # Category Name - Products are grouped by category in the catalog
        # This category will be validated when the script runs
        # If it doesn't exist and $createCategoryIfNotExists = $true, it will be created automatically
        # Example: "Exchange Online Groups", "Email", "Collaboration Tools"
        Category                   = "Exchange Online Groups"
    
        # ===== FORM =====
        # Optional dynamic form for collecting additional information during request
    
        # Dynamic Form ID - GUID of the form to attach to this product (optional)
        # How to find: Go to HelloID portal > Forms > Click form
        # URL will show: .../dynamicforms/editForm?dynamicFormGuid=<THE-GUID-YOU-NEED>
        #
        # Options:
        # - $null: No form attached - request goes directly to approval (recommended for simple products)
        # - "12345678-1234-1234-1234-123456789abc": Specific form by GUID
        #
        # Use forms when you need to collect additional information during request
        # Example: Ask for business justification, cost center, project code, etc.
        FormId                     = $null
    
        # ===== LIFECYCLE =====
        # Control what happens to products when users are disabled
    
        # Return On User Disable - Automatically return product when user account is disabled
        # - $true: Product is automatically returned when user is disabled (recommended for security)
        # - $false: Product remains active even when user is disabled
        ReturnOnUserDisable        = $true
    
        # ===== TIME LIMITS =====
        # Control whether products have time-based expiration
    
        # Has Time Limit - Whether products expire after a certain duration
        # - $false: Products remain active until manually returned (recommended)
        # - $true: Products automatically expire after OwnershipMaxDuration days
        HasTimeLimit               = $false
    
        # Manager Can Override Duration - Whether managers can change the expiration date
        # - $true: Managers can extend or shorten the product lifetime (recommended)
        # - $false: Duration is fixed and cannot be changed
        # Only applies when HasTimeLimit = $true
        ManagerCanOverrideDuration = $false
    
        # Limit Type - How the time limit is applied
        # Options:
        # - "Fixed": Product expires exactly at the specified duration
        # - "Maximum": Duration is the maximum allowed, can be shorter
        # Only applies when HasTimeLimit = $true
        LimitType                  = "Maximum"
    
        # Ownership Max Duration - Maximum number of days a product can be owned
        # Only applies when HasTimeLimit = $true
        # Common values: 90 (3 months), 365 (1 year), 3650 (10 years)
        OwnershipMaxDuration       = 365
    
        # ===== AGENT POOL =====
        # Which HelloID agent pool executes the product actions
    
        # Agent Pool - Name of the agent pool to use for executing actions
        # Options:
        # - $null or "Default": Use the default agent pool (recommended for most scenarios)
        # - "MyAgentPool": Use a specific agent pool by name
        # NOTE: If the specified agent pool doesn't exist, product creation will fail
        AgentPool                  = $null  # Use default agent pool
    
        # ===== PRICING =====
        # Show pricing information for products (optional - typically not used)
    
        # Show Price - Whether to display price information in the product catalog
        # - $false: No price shown (recommended - most organizations don't use this)
        # - $true: Price is displayed to users
        ShowPrice                  = $false
    
        # Price - The price to display (only shown if ShowPrice = $true)
        # Can be any numeric value, currency formatting is done by HelloID
        Price                      = $null
    
        # ===== RISK ASSESSMENT =====
        # Assign risk factors to products (optional - typically not used)
    
        # Has Risk Factor - Whether this product has an associated risk level
        # - $false: No risk factor shown (recommended - most organizations don't use this)
        # - $true: Risk factor is displayed and can be used for reporting/approval workflows
        HasRiskFactor              = $false
    
        # Risk Factor - Numeric risk level (only used if HasRiskFactor = $true)
        # Higher numbers = higher risk. Scale is defined by your organization.
        # Example: 1 = Low risk, 5 = Medium risk, 10 = High risk
        RiskFactor                 = 1
    
        # ===== LIMITS =====
        # Control the total number of times this product can be assigned
    
        # Max Count - Maximum total instances of this product across ALL users
        # This limits the TOTAL number of times the product can be assigned, not per user.
        #
        # Options:
        # - $null: Unlimited - product can be assigned as many times as needed
        # - any integer, e.g. 10: Product can only be assigned 10 times in total (across all users)
        MaxCount                   = $null
       
        # ===== PRODUCT ACTIONS DEFINITION =====
        # Define all product actions that will be executed during the product lifecycle
        # 
        # IMPORTANT: The action script variables referenced below (e.g., $addFullAccessPermissionScript)
        #            MUST be defined in the #region HelloId_Actions_Variables section of this script.
        #            The actual script content is kept there to avoid cluttering this configuration function.
        onRequest                  = @(
            # Example: Add actions that should run when product is requested (before approval)
            # [PSCustomObject]@{
            #     name               = "ActionName"
            #     scriptVariableName = "actionScriptVariableName" # use variable name as string reference to avoid cluttering configuration with script content
            #     runInCloud         = $false
            #     agentPoolName      = "" # If left empty, uses default agent pool
            # }
        )
        
        onApprove                  = @(
            # Group Membership - Grant membership to group
            [PSCustomObject]@{
                name               = "Grant-PermissionToDistributionGroup"
                scriptVariableName = "addExchangeOnlineUserToExchangeOnlineGroupScript" # use variable name as string reference to avoid cluttering configuration with script content
                runInCloud         = $false
                agentPoolName      = "" # If left empty, uses default agent pool
            }
        )
        
        onDeny                     = @(
            # Example: Add actions that should run when product request is denied
            # [PSCustomObject]@{
            #     name               = "ActionName"
            #     scriptVariableName = "actionScriptVariableName" # use variable name as string reference to avoid cluttering configuration with script content
            #     runInCloud         = $false
            #     agentPoolName      = "" # If left empty, uses default agent pool
            # }
        )
        
        onReturn                   = @(
            # Group Membership - Revoke membership from group
            [PSCustomObject]@{
                name               = "Revoke-PermissionFromDistributionGroup"
                scriptVariableName = "removeExchangeOnlineUserFromExchangeOnlineGroupScript" # use variable name as string reference to avoid cluttering configuration with script content
                runInCloud         = $false
                agentPoolName      = "" # If left empty, uses default agent pool
            }
        )
        
        onWithdrawn                = @(
            # Example: Add actions that should run when product request is withdrawn
            # [PSCustomObject]@{
            #     name               = "ActionName"
            #     scriptVariableName = "actionScriptVariableName" # use variable name as string reference to avoid cluttering configuration with script content
            #     runInCloud         = $false
            #     agentPoolName      = "" # If left empty, uses default agent pool
            # }
        )

        # NOTE: The following are NOT configured here because they have their own complex logic:
        # - Resource Owner (see "Resource Owner Configuration" section below) - calculated per source object or fixed
    }
}
######################################################################################
$createCategoryIfNotExists = $true  # If $true, creates the category automatically if not found

# Category properties (only used when creating new category)
$categoryIsEnabled = $true  # If $true, category is enabled and visible to users
$categoryUseFaIcon = $true  # If $true, uses Font Awesome icon; if $false, uses custom icon hash
# Specify WITHOUT 'fa-' prefix - it will be added automatically
# Browse icons at: https://fontawesome.com/v5/search?m=free
# Common examples: "address-book", "users", "envelope", "folder", "briefcase", "building"
$categoryFaIcon = "address-book"  # Font Awesome icon name (e.g., "address-book", "users")
$categoryIcon = $null  # Custom icon hash (e.g., "824D1F9AA5CCD3978535A6455B2186B5") or $null
######################################################################################

######################################################################################
# Resource Owner Configuration - Who manages these products
######################################################################################
# Choose resource owner mode: "Fixed" or "Calculated"
# - Fixed: Same resource owner group for all products
# - Calculated: Unique resource owner group per product (based on source object display name)
$resourceOwnerMode = "Calculated"

# Used when $resourceOwnerMode = "Fixed"
$productResourceOwner = "Local/__HelloID_Administrators"

# Used when $resourceOwnerMode = "Calculated"
# Result: $calculatedResourceOwnerGroupSource/$calculatedResourceOwnerGroupPrefix + sourceObject.DisplayName + $calculatedResourceOwnerGroupSuffix
# Example: "Local/Sales Resource Owner" for source object "Sales"
$calculatedResourceOwnerGroupSource = "Local"  # "AzureAD" or "Local"
$calculatedResourceOwnerGroupPrefix = ""  # Optional
$calculatedResourceOwnerGroupSuffix = " Resource Owner"  # At least prefix OR suffix required
######################################################################################

######################################################################################
# Update Behavior - When to update existing products (normally keep all $false)
######################################################################################
# WARNING: Only set $true when you've changed product settings and want to update ALL existing products
#          This will overwrite configured properties on every product that matches the filter
#          After updating, set back to $false to prevent unwanted updates on subsequent runs
$overwriteExistingProduct = $true

# Which product properties to update (if empty, no properties are updated - only actions if enabled below)
# IMPORTANT:
# - This setting only controls which product properties (name, description, etc.) should be updated
# - Product action lifecycle properties (onApprove, onReturn, etc.) CANNOT be defined here
# - Access groups are managed separately via $accessGroupUpdateBehavior below
# Add any properties you want to update - see API docs: https://tools4ever.stoplight.io/docs/helloid/ev3qn3p1nirbd-add-or-update-a-product
$productPropertiesToUpdate = @(
    "name"
    # "description"
    # "approvalWorkflow"
    # "visibility"
    # "requestComment"
    # "allowMultipleRequests"
    # "returnOnUserDisable"
)

# Update Resource Owner Group when product name changes
# Only applies when $resourceOwnerMode = "Calculated"
# WARNING: This setting renames HelloID groups when source object names change
# - If $true: When the source object name changes, the associated resource owner group will be renamed
#   Example: Source object renamed from "Sales" to "Sales Team" 
#   -> Group "Sales Resource Owner" will be renamed to "Sales Team Resource Owner"
# - If $false: Resource owner group names remain unchanged even when source object names change (safer default)
# Recommendation: Only set to $true if you actively manage source object names and want groups to stay in sync
$updateResourceOwnerGroupOnNameChange = $true

# Access Group Update Behavior - Controls whether/how to update access groups on existing products
# Access groups are managed via separate API calls (not part of product properties)
# - "None"    : Don't update access groups on existing products (default - safest option)
# - "Add"     : Add configured groups to existing groups (keeps existing + adds new)
# - "Replace" : Replace all existing groups with configured groups (removes existing)
# WARNING: "Replace" removes all existing access groups from the product - use with caution
$accessGroupUpdateBehavior = "None"  # Options: "None", "Add", "Replace"

# Set $true only when you've changed action scripts and want to update them
# WARNING: Overwriting actions is IRREVERSIBLE - original action scripts cannot be recovered
#          Make sure you have a backup of the original scripts before enabling this
$overwriteExistingProductAction = $false

# Set $true to add new actions to existing products (without overwriting existing ones)
$addMissingProductAction = $false

# Set $true to remove actions from existing products that are NOT in $actionsToUpdate
# WARNING: Removing actions is IRREVERSIBLE - deleted action scripts cannot be recovered
#          Only enable this when you intentionally want to clean up old/unused actions
#          Actions will be permanently deleted from products
#          Make sure you have a backup of the original scripts before enabling this
$removeUnconfiguredActions = $false

# Which actions to update - only specify action NAMES here, not the action scripts themselves
# The actual action scripts/content are defined in the #region HelloId_Actions_Variables section below
# Matching logic: If an action name listed here matches an existing action in HelloID, it gets updated
#                 If the name doesn't match any existing action, a new action is added
$actionsToUpdate = @{
    onApprove = @(
        "Grant-PermissionToDistributionGroup"
    )
    onReturn  = @(
        "Revoke-PermissionToDistributionGroup"
    )
    # onRequest = @()
    # onDeny = @()
    # onWithdrawn = @()
}
######################################################################################

#region HelloId_Actions_Variables
#region Add Exchange Online user to Group
<# First use a double-quoted here-string, where variables are replaced by their values here string (to be able to use a variable) #>
$addExchangeOnlineUserToExchangeOnlineGroupScript = @"
`$group = [Guid]::New((`$product.code.replace("$productIdentifierPrefix","")))

"@
<# Then use a single-quoted here-string, where variables are interpreted literally and reproduced exactly #> 
$addExchangeOnlineUserToExchangeOnlineGroupScript = $addExchangeOnlineUserToExchangeOnlineGroupScript + @'
$User = $requestedFor.userName

# Exchange Online Connection Configuration
# $EntraIdOrganization = "" # Set from Global Variable
# $EntraIdAppId = "" # Set from Global Variable
# $EntraIdCertificateBase64String = "" # Set from Global Variable
# $EntraIdCertificatePassword = "" # Set from Global Variable

# PowerShell commands to import
$commands = @(
    "Get-User"
    , "Get-DistributionGroup"
    , "Add-DistributionGroupMember"
)

# Set TLS to accept TLS, TLS 1.1 and TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12

# Set debug logging
$VerbosePreference = "SilentlyContinue"
$InformationPreference = "Continue"
$WarningPreference = "Continue"

#region functions
function Get-MSEntraCertificate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $CertificateBase64String,
        
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $CertificatePassword
    )
    try {
        $rawCertificate = [system.convert]::FromBase64String($CertificateBase64String)
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($rawCertificate, $CertificatePassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
        Write-Output $certificate
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
#endregion functions

try {
    # Import module
    $actionMessage = "importing module [ExchangeOnlineManagement]"
        
    $importModuleSplatParams = @{
        Name        = "ExchangeOnlineManagement"
        Cmdlet      = $commands
        Verbose     = $false
        ErrorAction = "Stop"
    }

    $null = Import-Module @importModuleSplatParams

    Write-Verbose "Imported module [ExchangeOnlineManagement]"

    # Convert base64 certificate string to certificate object
    $actionMessage = "converting base64 certificate string to certificate object"

    $certificate = Get-MSEntraCertificate -CertificateBase64String $EntraIdCertificateBase64String -CertificatePassword $EntraIdCertificatePassword

    Write-Verbose "Converted base64 certificate string to certificate object"

    # Connect to Microsoft Exchange Online
    # Docs: https://learn.microsoft.com/en-us/powershell/module/exchange/connect-exchangeonline?view=exchange-ps
    $actionMessage = "connecting to Microsoft Exchange Online"

    $createExchangeSessionSplatParams = @{
        Organization          = $EntraIdOrganization
        AppID                 = $EntraIdAppId
        Certificate           = $certificate
        CommandName           = $commands
        ShowBanner            = $false
        ShowProgress          = $false
        TrackPerformance      = $false
        SkipLoadingCmdletHelp = $true
        SkipLoadingFormatData = $true
        ErrorAction           = "Stop"
    }

    $null = Connect-ExchangeOnline @createExchangeSessionSplatParams

    # Query Exchange user (to use object in further actions)
    # More information about the cmdlet and the supported parameters: https://learn.microsoft.com/en-us/powershell/module/exchange/get-user?view=exchange-ps
    $actionMessage = "querying user with userprincipalname [$User]"
    $queryExchangeUserSplatParams = @{
        Identity    = "$User"
        ErrorAction = "Stop" # Makes sure the action enters the catch when an error occurs
    }

    $exchangeUser = Get-User @queryExchangeUserSplatParams
    Write-Information "Successfully queried Exchange user [$($queryExchangeUserSplatParams.Identity)]. DisplayName: [$($exchangeUser.DisplayName)], Guid: [$($exchangeUser.guid)], Identity: [$($exchangeUser.Identity)]"

    # Query Exchange group (to use object in further actions)
    # More information about the cmdlet and the supported parameters: https://learn.microsoft.com/en-us/powershell/module/exchange/get-group?view=exchange-ps
    $actionMessage = "querying group with guid [$group]"
    $queryexchangeDistributionGroupSplatParams = @{
        Identity    = "$group"
        ErrorAction = "Stop" # Makes sure the action enters the catch when an error occurs
    }

    $exchangeGroup = Get-DistributionGroup @queryexchangeDistributionGroupSplatParams
    Write-Information "Successfully queried Exchange group [$($queryexchangeDistributionGroupSplatParams.Identity)]. DisplayName: [$($exchangeGroup.DisplayName)], Guid: [$($exchangeGroup.guid)], Identity: [$($exchangeGroup.Identity)]"

    # Add Exchange Online user to Exchange Online group
    # Microsoft docs: https://learn.microsoft.com/en-us/powershell/module/exchange/add-distributiongroupmember?view=exchange-ps
    $actionMessage = "adding Exchange Online user [$($exchangeUser.DisplayName) ($($exchangeUser.Guid))] to Exchange Online group [$($exchangeGroup.DisplayName) ($($exchangeGroup.Guid))]"
    $addExchangeOnlineUserToGroupSplatParams = @{
        Identity                        = $exchangeGroup.guid
        Member                          = $exchangeUser.guid
        BypassSecurityGroupManagerCheck = $true
        Confirm                         = $false
        Verbose                         = $false
        ErrorAction                     = "Stop"
    }
    $addExchangeOnlineUserToGroup = Add-DistributionGroupMember @addExchangeOnlineUserToGroupSplatParams
    
    # Send auditlog to HelloID
    $Log = @{
        Action            = "GrantMembership" # optional. ENUM (undefined = default) 
        System            = "ExchangeOnline" # optional (free format text) 
        Message           = "Successfully added Exchange Online user [$($exchangeUser.DisplayName) ($($exchangeUser.Guid))] to Exchange Online group [$($exchangeGroup.DisplayName) ($($exchangeGroup.Guid))]" # required (free format text) 
        IsError           = $false # optional. Elastic reporting purposes only. (default = $false. $true = Executed action returned an error) 
        TargetDisplayName = $exchangeUser.DisplayName # optional (free format text)
        TargetIdentifier  = $([string]$exchangeUser.Guid) # optional (free format text)
    }
    Write-Information -Tags "Audit" -MessageData $log
}
catch {
    $ex = $PSItem
    if (-not [string]::IsNullOrEmpty($ex.Exception.Data.RemoteException.Message)) {
        $warningMessage = "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($ex.Exception.Data.RemoteException.Message)"
        $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Data.RemoteException.Message)"
    }
    else {
        $warningMessage = "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
    }
    if ($errorMessage -like "*Microsoft.Exchange.Management.Tasks.MemberAlreadyExistsException*") {
        $Log = @{
            Action            = "GrantMembership" # optional. ENUM (undefined = default) 
            System            = "ExchangeOnline" # optional (free format text) 
            Message           = "Skipped $($actionMessage). Reason: User is already a member."
            IsError           = $false # optional. Elastic reporting purposes only. (default = $false. $true = Executed action returned an error) 
            TargetDisplayName = $exchangeUser.DisplayName # optional (free format text)
            TargetIdentifier  = $([string]$exchangeUser.Guid) # optional (free format text)
        }
    
        Write-Information -Tags "Audit" -MessageData $log
    } 
    else {
        $Log = @{
            Action            = "GrantMembership" # optional. ENUM (undefined = default) 
            System            = "ExchangeOnline" # optional (free format text) 
            Message           = $errorMessage # required (free format text) 
            IsError           = $true # optional. Elastic reporting purposes only. (default = $false. $true = Executed action returned an error) 
            TargetDisplayName = $exchangeUser.DisplayName # optional (free format text)
            TargetIdentifier  = $([string]$exchangeUser.Guid) # optional (free format text)
        }
        
        Write-Information -Tags "Audit" -MessageData $log
        Write-Warning $warningMessage
        Write-Error $errorMessage
    }
}
finally {
    # Docs: https://learn.microsoft.com/en-us/powershell/module/exchange/disconnect-exchangeonline?view=exchange-ps
    $deleteExchangeSessionSplatParams = @{
        Confirm     = $false
        ErrorAction = "Stop"
    }
    $null = Disconnect-ExchangeOnline @deleteExchangeSessionSplatParams
}
'@
#endregion Add Exchange Online user to Group

#region Remove Exchange Online user from Group
<# First use a double-quoted here-string, where variables are replaced by their values here string (to be able to use a variable) #>
$removeExchangeOnlineUserFromExchangeOnlineGroupScript = @"
`$group = [Guid]::New((`$product.code.replace("$productIdentifierPrefix","")))

"@
<# Then use a single-quoted here-string, where variables are interpreted literally and reproduced exactly #> 
$removeExchangeOnlineUserFromExchangeOnlineGroupScript = $removeExchangeOnlineUserFromExchangeOnlineGroupScript + @'
$User = $requestedFor.userName

# Exchange Online Connection Configuration
# $EntraIdOrganization = "" # Set from Global Variable
# $EntraIdAppId = "" # Set from Global Variable
# $EntraIdCertificateBase64String = "" # Set from Global Variable
# $EntraIdCertificatePassword = "" # Set from Global Variable

# PowerShell commands to import
$commands = @(
    "Get-User"
    , "Get-DistributionGroup"
    , "Remove-DistributionGroupMember"
)

# Set TLS to accept TLS, TLS 1.1 and TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12

# Set debug logging
$VerbosePreference = "SilentlyContinue"
$InformationPreference = "Continue"
$WarningPreference = "Continue"

#region functions
function Get-MSEntraCertificate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $CertificateBase64String,
        
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $CertificatePassword
    )
    try {
        $rawCertificate = [system.convert]::FromBase64String($CertificateBase64String)
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($rawCertificate, $CertificatePassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
        Write-Output $certificate
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
#endregion functions

try {
    # Import module
    $actionMessage = "importing module [ExchangeOnlineManagement]"
        
    $importModuleSplatParams = @{
        Name        = "ExchangeOnlineManagement"
        Cmdlet      = $commands
        Verbose     = $false
        ErrorAction = "Stop"
    }

    $null = Import-Module @importModuleSplatParams

    Write-Verbose "Imported module [ExchangeOnlineManagement]"

    # Convert base64 certificate string to certificate object
    $actionMessage = "converting base64 certificate string to certificate object"

    $certificate = Get-MSEntraCertificate -CertificateBase64String $EntraIdCertificateBase64String -CertificatePassword $EntraIdCertificatePassword

    Write-Verbose "Converted base64 certificate string to certificate object"

    # Connect to Microsoft Exchange Online
    # Docs: https://learn.microsoft.com/en-us/powershell/module/exchange/connect-exchangeonline?view=exchange-ps
    $actionMessage = "connecting to Microsoft Exchange Online"

    $createExchangeSessionSplatParams = @{
        Organization          = $EntraIdOrganization
        AppID                 = $EntraIdAppId
        Certificate           = $certificate
        CommandName           = $commands
        ShowBanner            = $false
        ShowProgress          = $false
        TrackPerformance      = $false
        SkipLoadingCmdletHelp = $true
        SkipLoadingFormatData = $true
        ErrorAction           = "Stop"
    }

    $null = Connect-ExchangeOnline @createExchangeSessionSplatParams

    # Query Exchange user (to use object in further actions)
    # More information about the cmdlet and the supported parameters: https://learn.microsoft.com/en-us/powershell/module/exchange/get-user?view=exchange-ps
    $actionMessage = "querying user with userprincipalname [$User]"
    $queryExchangeUserSplatParams = @{
        Identity    = "$User"
        ErrorAction = "Stop" # Makes sure the action enters the catch when an error occurs
    }

    $exchangeUser = Get-User @queryExchangeUserSplatParams
    Write-Information "Successfully queried Exchange user [$($queryExchangeUserSplatParams.Identity)]. DisplayName: [$($exchangeUser.DisplayName)], Guid: [$($exchangeUser.guid)], Identity: [$($exchangeUser.Identity)]"

    # Query Exchange group (to use object in further actions)
    # More information about the cmdlet and the supported parameters: https://learn.microsoft.com/en-us/powershell/module/exchange/get-group?view=exchange-ps
    $actionMessage = "querying group with guid [$group]"
    $queryexchangeDistributionGroupSplatParams = @{
        Identity    = "$group"
        ErrorAction = "Stop" # Makes sure the action enters the catch when an error occurs
    }

    $exchangeGroup = Get-DistributionGroup @queryexchangeDistributionGroupSplatParams
    Write-Information "Successfully queried Exchange group [$($queryexchangeDistributionGroupSplatParams.Identity)]. DisplayName: [$($exchangeGroup.DisplayName)], Guid: [$($exchangeGroup.guid)], Identity: [$($exchangeGroup.Identity)]"

    # Remove Exchange Online user from Exchange Online group
    # Microsoft docs: https://learn.microsoft.com/en-us/powershell/module/exchange/remove-distributiongroupmember?view=exchange-ps
    $actionMessage = "removing Exchange Online user [$($exchangeUser.DisplayName) ($($exchangeUser.Guid))] from Exchange Online group [$($exchangeGroup.DisplayName) ($($exchangeGroup.Guid))]"
    $removeExchangeOnlineUserFromGroupSplatParams = @{
        Identity                        = $exchangeDistributionGroup.guid
        Member                          = $exchangeUser.guid
        BypassSecurityGroupManagerCheck = $true
        Confirm                         = $false
        Verbose                         = $false
        ErrorAction                     = "Stop"
    } 
    $removeExchangeOnlineUserFromGroup = Remove-DistributionGroupMember @removeExchangeOnlineUserFromGroupSplatParams

    # Send auditlog to HelloID
    $Log = @{
        Action            = "RevokeMembership" # optional. ENUM (undefined = default) 
        System            = "Exchange" # optional (free format text) 
        Message           = "Successfully removed Exchange Online user [$($exchangeUser.DisplayName) ($($exchangeUser.Guid))] from Exchange Online group [$($exchangeGroup.DisplayName) ($($exchangeGroup.Guid))]" # required (free format text) 
        IsError           = $false # optional. Elastic reporting purposes only. (default = $false. $true = Executed action returned an error) 
        TargetDisplayName = $exchangeUser.DisplayName # optional (free format text)
        TargetIdentifier  = $([string]$exchangeUser.Guid) # optional (free format text)
    }
    Write-Information -Tags "Audit" -MessageData $log
}
catch {
    $ex = $PSItem
    if (-not [string]::IsNullOrEmpty($ex.Exception.Data.RemoteException.Message)) {
        $warningMessage = "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($ex.Exception.Data.RemoteException.Message)"
        $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Data.RemoteException.Message)"
    }
    else {
        $warningMessage = "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
    }

    if ($errorMessage -like "*Microsoft.Exchange.Management.Tasks.MemberNotFoundException*") {
        $Log = @{
            Action            = "RevokeMembership" # optional. ENUM (undefined = default) 
            System            = "ExchangeOnline" # optional (free format text) 
            Message           = "Skipped $($actionMessage). Reason: User is already no longer a member."
            IsError           = $false # optional. Elastic reporting purposes only. (default = $false. $true = Executed action returned an error) 
            TargetDisplayName = $exchangeUser.DisplayName # optional (free format text)
            TargetIdentifier  = $([string]$exchangeUser.Guid) # optional (free format text)
        }
    
        Write-Information -Tags "Audit" -MessageData $log
    }
    elseif ($errorMessage -like "*Microsoft.Exchange.Configuration.Tasks.ManagementObjectNotFoundException*") {
        $Log = @{
            Action            = "RevokeMembership" # optional. ENUM (undefined = default) 
            System            = "ExchangeOnline" # optional (free format text) 
            Message           = "Skipped $($actionMessage). Reason: Group no longer exists."
            IsError           = $false # optional. Elastic reporting purposes only. (default = $false. $true = Executed action returned an error) 
            TargetDisplayName = $exchangeUser.DisplayName # optional (free format text)
            TargetIdentifier  = $([string]$exchangeUser.Guid) # optional (free format text)
        }
    
        Write-Information -Tags "Audit" -MessageData $log
    } 
    else {
        $Log = @{
            Action            = "RevokeMembership" # optional. ENUM (undefined = default) 
            System            = "ExchangeOnline" # optional (free format text) 
            Message           = $errorMessage # required (free format text) 
            IsError           = $true # optional. Elastic reporting purposes only. (default = $false. $true = Executed action returned an error) 
            TargetDisplayName = $exchangeUser.DisplayName # optional (free format text)
            TargetIdentifier  = $([string]$exchangeUser.Guid) # optional (free format text)
        }
        
        Write-Information -Tags "Audit" -MessageData $log
        Write-Warning $warningMessage
        Write-Error $errorMessage
    }
}
finally {
    # Docs: https://learn.microsoft.com/en-us/powershell/module/exchange/disconnect-exchangeonline?view=exchange-ps
    $deleteExchangeSessionSplatParams = @{
        Confirm     = $false
        ErrorAction = "Stop"
    }
    $null = Disconnect-ExchangeOnline @deleteExchangeSessionSplatParams
}
'@
#endregion Remove Exchange Online user from Group
#endregion HelloId_Actions_Variables

#region functions
function Write-StatusMessage {
    <#
    .SYNOPSIS
    Writes a status message to the appropriate logging system.
    
    .DESCRIPTION
    When running locally: Uses native PowerShell cmdlets (Write-Information, Write-Warning, Write-Error)
    When running in HelloID: Uses HelloID's native Hid-Write-Status function
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Message,

        [Parameter(Mandatory = $true)]
        [String]
        $Event
    )
    
    if ($null -eq $portalBaseUrl) {
        # Running locally - use native PowerShell cmdlets
        switch ($Event) {
            "Information" { Write-Information ($Message) -InformationAction Continue }
            "Warning" { Write-Warning ($Message) -WarningAction Continue }
            "Success" { Write-Information ($Message) -InformationAction Continue }
            "Error" { Write-Error ($Message) -ErrorAction Continue }
            "Critical" { Write-Error ($Message) -ErrorAction Continue }
            "Failed" { Write-Error ($Message) -ErrorAction Continue }
        }
    }
    else {
        # Running in HelloID - use native HelloID function
        Hid-Write-Status -Message $Message -Event $Event
    }
}

function Write-SummaryMessage {
    <#
    .SYNOPSIS
    Writes a summary message to the appropriate logging system.
    
    .DESCRIPTION
    When running locally: Uses native PowerShell cmdlets (Write-Information, Write-Warning, Write-Error)
    When running in HelloID: Uses HelloID's native Hid-Write-Summary function
    #>
    [cmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Message,

        [Parameter(Mandatory = $true)]
        [String]
        $Event
    )
    
    if ($null -eq $portalBaseUrl) {
        # Running locally - use native PowerShell cmdlets
        switch ($Event) {
            "Information" { Write-Information ($Message) -InformationAction Continue }
            "Warning" { Write-Warning ($Message) -WarningAction Continue }
            "Success" { Write-Information ($Message) -InformationAction Continue }
            "Error" { Write-Error ($Message) -ErrorAction Continue }
            "Critical" { Write-Error ($Message) -ErrorAction Continue }
            "Failed" { Write-Error ($Message) -ErrorAction Continue }
        }
    }
    else {
        # Running in HelloID - use native HelloID function
        Hid-Write-Summary -Message $Message -Event $Event
    }
}

function Resolve-HelloIDError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq "System.Net.WebException") {
            if ($null -ne $ErrorObject.Exception.Response) {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {
                    $httpErrorObj.ErrorDetails = $streamReaderResponse
                }
            }
        }
        try {
            $errorDetailsObject = ($httpErrorObj.ErrorDetails | ConvertFrom-Json)
            # error message can be either in [resultMsg] or [message] or [textResult] or [error]
            if ([bool]($errorDetailsObject.PSobject.Properties.name -eq "resultMsg")) {
                $httpErrorObj.FriendlyMessage = $errorDetailsObject.resultMsg
            }
            elseif ([bool]($errorDetailsObject.PSobject.Properties.name -eq "message")) {
                $httpErrorObj.FriendlyMessage = $errorDetailsObject.message
            }
            elseif ([bool]($errorDetailsObject.PSobject.Properties.name -eq "textResult")) {
                $httpErrorObj.FriendlyMessage = $errorDetailsObject.textResult
            }
            elseif ([bool]($errorDetailsObject.PSobject.Properties.name -eq "error")) {
                $httpErrorObj.FriendlyMessage = $errorDetailsObject.error
            }
            else {
                $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails # Temporarily assignment
            }
        }
        catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
        }
        Write-Output $httpErrorObj
    }
}

function Resolve-ExchangeOnlineError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            if ($null -ne $ErrorObject.Exception.Response) {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {
                    $httpErrorObj.ErrorDetails = $streamReaderResponse
                }
            }
        }
        try {
            $errorObjectConverted = $ErrorObject | ConvertFrom-Json -ErrorAction Stop

            if ($null -ne $errorObjectConverted.error_description) {
                $httpErrorObj.FriendlyMessage = $errorObjectConverted.error_description
            }
            elseif ($null -ne $errorObjectConverted.error) {
                if ($null -ne $errorObjectConverted.error.message) {
                    $httpErrorObj.FriendlyMessage = $errorObjectConverted.error.message
                    if ($null -ne $errorObjectConverted.error.code) { 
                        $httpErrorObj.FriendlyMessage = $httpErrorObj.FriendlyMessage + " Error code: $($errorObjectConverted.error.code)"
                    }
                }
                else {
                    $httpErrorObj.FriendlyMessage = $errorObjectConverted.error
                }
            }
            else {
                $httpErrorObj.FriendlyMessage = $ErrorObject
            }
        }
        catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
        }
        Write-Output $httpErrorObj
    }
}

function Get-ResourceOwnerGroupName {
    <#
    .SYNOPSIS
    Calculates the resource owner group name based on source object display name and configuration.
    
    .DESCRIPTION
    Helper function to eliminate code duplication for resource owner group name calculation.
    Returns the full group name with source prefix (e.g., "Local/Sales Resource Owner").
    
    .PARAMETER SourceObjectDisplayName
    The display name of the source object to use in the group name.
    
    .PARAMETER IncludeSourcePrefix
    If true, includes the source prefix (e.g., "Local/") in the returned name.
    If false, returns only the group name without source prefix (for API calls).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$SourceObjectDisplayName,
        
        [Parameter(Mandatory = $false)]
        [bool]$IncludeSourcePrefix = $true
    )
    
    process {
        # Calculate group name based on configuration
        if (-not[string]::IsNullOrEmpty($calculatedResourceOwnerGroupPrefix) -or -not[string]::IsNullOrEmpty($calculatedResourceOwnerGroupSuffix)) {
            $groupName = "$($calculatedResourceOwnerGroupPrefix)" + "$($SourceObjectDisplayName)" + "$($calculatedResourceOwnerGroupSuffix)"
        }
        else {
            # Fallback if no prefix/suffix configured (should not happen due to validation)
            $groupName = "$($SourceObjectDisplayName) Resource Owners"
        }
        
        if ($IncludeSourcePrefix) {
            return "$($calculatedResourceOwnerGroupSource)/$groupName"
        }
        else {
            return $groupName
        }
    }
}

function Invoke-HelloIDRestMethod {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Method,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Uri,

        [object]
        $Body,

        [string]
        $ContentType = "application/json",

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]
        $Headers,

        [Parameter()]
        [Boolean]
        $UsePaging = $false,

        [Parameter()]
        [Int]
        $Skip = 0,

        [Parameter()]
        [Int]
        $Take = 1000
    )

    process {
        try {
            $splatParams = @{
                Uri             = $Uri
                Headers         = $Headers
                Method          = $Method
                ContentType     = $ContentType
                UseBasicParsing = $true
                Verbose         = $false
                ErrorAction     = "Stop"
            }

            if ($Body) {
                $splatParams["Body"] = ([System.Text.Encoding]::UTF8.GetBytes($Body))
            }

            if ($UsePaging -eq $true) {
                $result = [System.Collections.ArrayList]@()
                $startUri = $splatParams.Uri
                do {
                    # Determine separator based on whether URI already contains query parameters
                    $separator = if ($startUri -match '\?') { '&' } else { '?' }
                    $splatParams["Uri"] = $startUri + "$($separator)take=$($take)&skip=$($skip)"
                    $response = (Invoke-RestMethod @splatParams)
                    if ([bool]($response.PSobject.Properties.name -eq "data")) {
                        $response = $response.data
                    }
                    if ($response -is [array]) {
                        [void]$result.AddRange($response)
                    }
                    else {
                        [void]$result.Add($response)
                    }
        
                    $skip += $take
                } while (($response | Measure-Object).Count -eq $take)
            }
            else {
                $result = Invoke-RestMethod @splatParams
            }

            Write-Output $result
        }
        catch {
            throw $_
        }
    }
}

function Get-MSEntraCertificate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $CertificateBase64String,
        
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $CertificatePassword
    )
    try {
        $rawCertificate = [system.convert]::FromBase64String($CertificateBase64String)
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($rawCertificate, $CertificatePassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
        Write-Output $certificate
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
#endregion functions

#region script
Write-StatusMessage -Event Information -Message "Starting synchronization of Exchange Online Groups to HelloID Self service Products"

# Validate Calculated mode configuration
if ($resourceOwnerMode -eq "Calculated") {
    if ([string]::IsNullOrEmpty($calculatedResourceOwnerGroupPrefix) -and [string]::IsNullOrEmpty($calculatedResourceOwnerGroupSuffix)) {
        Write-SummaryMessage -Event "Failed" -Message "Configuration error: When using resourceOwnerMode 'Calculated', at least one of calculatedResourceOwnerGroupPrefix or calculatedResourceOwnerGroupSuffix must be configured. Both cannot be empty."
        exit
    }
}

# Exchange Online actions
try {
    Write-StatusMessage -Event Information -Message "------[Exchange Online]-----------"

    # Import module
    $actionMessage = "importing module [ExchangeOnlineManagement]"
    
    $importModuleSplatParams = @{
        Name        = "ExchangeOnlineManagement"
        Cmdlet      = $commands
        Verbose     = $false
        ErrorAction = "Stop"
    }

    $null = Import-Module @importModuleSplatParams
    Write-Information "Imported module [$($importModuleSplatParams.Name)]"

    # Convert base64 certificate string to certificate object
    $actionMessage = "converting base64 certificate string to certificate object"

    $certificate = Get-MSEntraCertificate -CertificateBase64String $EntraIdCertificateBase64String -CertificatePassword $EntraIdCertificatePassword

    Write-Verbose "Converted base64 certificate string to certificate object"

    # Retrieving certificate
    $actionMessage = "retrieving certificate"
    $certificate = Get-MSEntraCertificate -CertificateBase64String $EntraIdCertificateBase64String -CertificatePassword $EntraIdCertificatePassword

    # Connect to Microsoft Exchange Online
    # Docs: https://learn.microsoft.com/en-us/powershell/module/exchange/connect-exchangeonline?view=exchange-ps
    $actionMessage = "connecting to Microsoft Exchange Online"

    $createExchangeSessionSplatParams = @{
        Organization          = $EntraIdOrganization
        AppID                 = $EntraIdAppId
        Certificate           = $certificate
        CommandName           = $commands
        ShowBanner            = $false
        ShowProgress          = $false
        TrackPerformance      = $false
        SkipLoadingCmdletHelp = $true
        SkipLoadingFormatData = $true
        ErrorAction           = "Stop"
    }

    $null = Connect-ExchangeOnline @createExchangeSessionSplatParams
    
    Write-Information "Successfully connected to Exchange Online"

    # Get Exchange Online Groups
    $actionMessage = "querying Microsoft Exchange Online Groups that match filter [$exchangeOnlineGroupsFilter] and retrieving properties [$($exchangeOnlineGroupPropertiesToRetrieve -join ", ")]"
    $getMicrosoftExchangeOnlineGroupsSplatParams = @{
        Properties  = $exchangeOnlineGroupPropertiesToRetrieve
        ResultSize  = "Unlimited"
        Verbose     = $false
        ErrorAction = 'Stop'
    }

    # Only apply filter if specified, otherwise get all Groups
    if (-not[string]::IsNullOrEmpty($exchangeOnlineGroupsFilter)) {
        $getMicrosoftExchangeOnlineGroupsSplatParams['Filter'] = $exchangeOnlineGroupsFilter
    }

    $exchangeOnlineGroups = Get-DistributionGroup @getMicrosoftExchangeOnlineGroupsSplatParams | Select-Object $exchangeOnlineGroupPropertiesToRetrieve
    Write-StatusMessage -Event Success -Message "Successfully queried Exchange Online groups that match filter [$exchangeOnlineGroupsFilter]. Result count: $(($exchangeOnlineGroups | Measure-Object).Count)"

    # Build list of source objects in scope based on query results (to use in further actions)
    $sourceObjectsInScope = [System.Collections.Generic.List[Object]]::New()
    foreach ($exchangeOnlineGroup in $exchangeOnlineGroups) {
        [void]$sourceObjectsInScope.Add($exchangeOnlineGroup)
    }

    if (($sourceObjectsInScope | Measure-Object).Count -eq 0) {
        Write-SummaryMessage -Event "Failed" -Message "No Source objects in scope have been found"
        exit
    }

    # Create indexed hashtable for fast source object lookups
    # Index by product code for efficient matching during product updates
    # NOTE: This hashtable is created from ALL source objects to ensure correct obsolete product detection
    # NOTE: This assumes Code template starts with $productIdentifierPrefix. If you customize the Code template,
    #       ensure it still starts with the $productIdentifierPrefix for proper matching.
    $sourceObjectsInScopeGrouped = $sourceObjectsInScope | Group-Object -Property { ("$productIdentifierPrefix" + "$($_.$sourceObjectUniqueProperty)").Replace("-", "") } -AsHashTable -AsString
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-ExchangeOnlineError -ErrorObject $ex
        $errorMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
        $warningMessage = "Error at Line [$($errorObj.ScriptLineNumber)]: $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
        $warningMessage = "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    Write-StatusMessage -Event "Error" -Message $warningMessage
    Write-SummaryMessage -Event "Failed" -Message $errorMessage

    # Note: Not exiting here to ensure the Disconnect-ExchangeOnline command in the finally block is executed to clean up the session properly
    # Set critical error flag to true to indicate that a critical error occurred during Exchange Online actions. This will be used in the finally block to determine whether to exit the script to prevent further execution.
    $criticalErrorOccurred = $true
}
finally {
    # Disconnect from Microsoft Exchange Online
    # Docs: https://learn.microsoft.com/en-us/powershell/module/exchange/disconnect-exchangeonline?view=exchange-ps
    $actionMessage = "disconnecting from Microsoft Exchange Online"

    $deleteExchangeSessionSplatParams = @{
        Confirm     = $false
        ErrorAction = "Stop"
    }

    $null = Disconnect-ExchangeOnline @deleteExchangeSessionSplatParams
    
    Write-Information "Disconnected from Microsoft Exchange Online"

    # Note: Exit with error if critical error occurred to prevent further execution
    if ($criticalErrorOccurred -eq $true) {
        exit
    }
}

Write-StatusMessage -Event Information -Message "------[HelloID]------"
try {
    # Create authorization headers with HelloID API key
    $actionMessage = "creating authorization headers with HelloID API key"

    $pair = "$($helloIDPortalApiKey):$($helloIDPortalApiSecret)"
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
    $base64 = [System.Convert]::ToBase64String($bytes)
    $key = "Basic $base64"
    $helloIDHeaders = @{"authorization" = $Key }

    Write-Verbose "Created authorization headers with HelloID API key"

    # Get HelloID agent pools
    $actionMessage = "querying agent pools from HelloID"
    $getHelloIDAgentPoolsSplatParams = @{
        Uri       = "$($helloIDPortalBaseUrl)/api/v1/agentpools"
        Method    = 'GET'
        Headers   = $helloIDHeaders
        UsePaging = $true
    }
    $helloIDAgentPools = Invoke-HelloIDRestMethod @getHelloIDAgentPoolsSplatParams

    # Create indexed hashtable for fast agent pool lookups
    # Index by name for efficient matching during product action calculations
    $helloIDAgentPoolsGrouped = $helloIDAgentPools | Group-Object -Property "name" -AsHashTable -AsString

    # Filter for default agent pool
    $actionMessage = "filtering for default agent pool"
    $defaultHelloIDAgentPool = $null
    $defaultHelloIDAgentPool = $helloIDAgentPools | Where-Object { $_.options -eq "1" }
    
    Write-StatusMessage -Event Success -Message "Successfully queried agent pools from HelloID. Result count: $(($helloIDAgentPools | Measure-Object).Count)"

    # Get HelloID products
    $actionMessage = "querying Self service products from HelloID"
    $getHelloIDProductsSplatParams = @{
        Uri       = "$($helloIDPortalBaseUrl)/api/v1/products"
        Method    = 'GET'
        Headers   = $helloIDHeaders
        UsePaging = $true
    }
    $helloIDSelfServiceProducts = Invoke-HelloIDRestMethod @getHelloIDProductsSplatParams

    # Filter for products with specified ProductSKU prefix
    $actionMessage = "filtering products with specified SKU prefix [$productIdentifierPrefix]"
    # NOTE: This assumes Code template starts with productIdentifierPrefix. If you customize the Code template,
    #       ensure it still starts with the productIdentifierPrefix for proper filtering.
    $helloIDSelfServiceProductsInScope = $null
    $helloIDSelfServiceProductsInScope = $helloIDSelfServiceProducts | Where-Object { $_.code -like "$productIdentifierPrefix*" }

    $helloIDSelfServiceProductsInScopeGrouped = $helloIDSelfServiceProductsInScope | Group-Object -Property "code" -AsHashTable -AsString
    Write-StatusMessage -Event Success -Message "Successfully queried Self service products from HelloID (after filtering for products with specified SKU prefix). Result count: $(($helloIDSelfServiceProductsInScope | Measure-Object).Count)"

    # Validate Form exists if specified
    if (-not [string]::IsNullOrEmpty($productFormId)) {
        $actionMessage = "validating form with ID [$productFormId] exists in HelloID"
        $getHelloIDFormSplatParams = @{
            Uri       = "$($helloIDPortalBaseUrl)/api/v1/forms/$($productFormId)"
            Method    = 'GET'
            Headers   = $helloIDHeaders
            UsePaging = $false
        }
        $formCheck = Invoke-HelloIDRestMethod @getHelloIDFormSplatParams
        Write-StatusMessage -Event Success -Message "Validated: Form [$($formCheck.name)] exists in HelloID (ID: $productFormId)"
    }

    # Get HelloID groups
    $actionMessage = "querying groups from HelloID"
    $getHelloIDGroupsSplatParams = @{
        Uri       = "$($helloIDPortalBaseUrl)/api/v1/groups"
        Method    = 'GET'
        Headers   = $helloIDHeaders
        UsePaging = $true
    }
    $helloIDGroups = Invoke-HelloIDRestMethod @getHelloIDGroupsSplatParams

    $helloIDGroupsInScope = $null
    $helloIDGroupsInScope = $helloIDGroups 

    $helloIDGroupsInScope | Add-Member -MemberType NoteProperty -Name SourceAndName -Value $null
    $helloIDGroupsInScope | ForEach-Object {
        if ([string]::IsNullOrEmpty($_.source)) {
            $_.source = "Local"
        }
        $_.SourceAndName = "$($_.source)/$($_.name)"
    }
    $helloIDGroupsInScopeGroupedBySourceAndName = $helloIDGroupsInScope | Group-Object -Property "SourceAndName" -AsHashTable -AsString
    Write-StatusMessage -Event Success -Message "Successfully queried Groups from HelloID. Result count: $(($helloIDGroupsInScope | Measure-Object).Count)"

    # Get HelloID selfservice categories
    $actionMessage = "querying Self service categories from HelloID"
    $getHelloIDSelfserviceCategoriesSplatParams = @{
        Uri       = "$($helloIDPortalBaseUrl)/api/v1/selfservice/categories"
        Method    = 'GET'
        Headers   = $helloIDHeaders
        UsePaging = $true
    }
    $helloIDSelfserviceCategories = Invoke-HelloIDRestMethod @getHelloIDSelfserviceCategoriesSplatParams
    $helloIDSelfserviceCategoriesGrouped = $helloIDSelfserviceCategories | Group-Object -Property name -AsHashTable -AsString
    Write-StatusMessage -Event Success -Message "Successfully queried Self service categories from HelloID. Result count: $(($helloIDSelfserviceCategories | Measure-Object).Count)"
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") -or
        $($ex.Exception.GetType().FullName -eq "System.Net.WebException")) {
        $errorObj = Resolve-HelloIDError -ErrorObject $ex
        $warningMessage = "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
        $errorMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
    }
    else {
        $warningMessage = "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
    }
    Write-StatusMessage -Event "Error" -Message $warningMessage
    Write-SummaryMessage -Event "Failed" -Message $errorMessage
    exit
}

Write-StatusMessage -Event Information -Message "------[Calculations of combined data]------"
# Show test run configuration if enabled
if ($testRun -eq $true) {
    Write-StatusMessage -Event Information -Message "Test run enabled with operation limits:"
    Write-StatusMessage -Event Information -Message "  Max Creates: $testRunMaxCreates"
    Write-StatusMessage -Event Information -Message "  Max Updates: $testRunMaxUpdates"
    Write-StatusMessage -Event Information -Message "  Max Deletes: $testRunMaxDeletes"
}
# Calculate new and obsolete products
try {
    # Generate sample product config to determine category and access groups needed
    $actionMessage = "generating sample product configuration to determine category and access groups"
    $sampleSourceObject = $sourceObjectsInScope[0]
    $sampleProductConfigSplatParams = @{
        SourceObject               = $sampleSourceObject
        ProductIdentifierPrefix    = $productIdentifierPrefix
        SourceObjectUniqueProperty = $sourceObjectUniqueProperty
    }
    $sampleProductConfig = New-HelloIDProductConfiguration @sampleProductConfigSplatParams

    # Validate/create category
    $actionMessage = "validating category [$($sampleProductConfig.Category)]"
    $categoryName = $sampleProductConfig.Category
    if (-not $helloIDSelfserviceCategoriesGrouped.ContainsKey($categoryName)) {
        if ($createCategoryIfNotExists -eq $true) {
            # Create the category
            try {
                $actionMessage = "creating category [$categoryName]"
                $categoryBody = @{
                    name      = $categoryName
                    isEnabled = $categoryIsEnabled
                    useFaIcon = $categoryUseFaIcon
                    faIcon    = "fa-$($categoryFaIcon)"
                    icon      = $categoryIcon
                }

                $createHelloIDSelfserviceCategorySplatParams = @{
                    Uri     = "$($helloIDPortalBaseUrl)/api/v1/selfservice/categories"
                    Method  = 'POST'
                    Headers = $helloIDHeaders
                    Body    = ($categoryBody | ConvertTo-Json -Depth 10)
                }

                if ($dryRun -eq $false) {
                    $createdCategory = Invoke-HelloIDRestMethod @createHelloIDSelfserviceCategorySplatParams
                    $helloIDSelfserviceCategoriesGrouped[$categoryName] = $createdCategory
                    Write-StatusMessage -Event Success -Message "Successfully created HelloID Self service Category [$categoryName]"
                }
                else {
                    Write-StatusMessage -Event Warning -Message "DryRun: Would create HelloID Self service Category [$categoryName]"
                    # Create a mock category object for dry run
                    $mockCategory = [PSCustomObject]@{
                        selfServiceCategoryGUID = "00000000-0000-0000-0000-000000000000"
                        name                    = $categoryName
                        isEnabled               = $categoryIsEnabled
                        useFaIcon               = $categoryUseFaIcon
                        faIcon                  = "fa-$($categoryFaIcon)"
                        icon                    = $categoryIcon
                    }
                    $helloIDSelfserviceCategoriesGrouped[$categoryName] = $mockCategory
                }
            }
            catch {
                $ex = $PSItem
                if ($($ex.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") -or
                    $($ex.Exception.GetType().FullName -eq "System.Net.WebException")) {
                    $errorObj = Resolve-HelloIDError -ErrorObject $ex
                    $warningMessage = "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
                    $errorMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
                }
                else {
                    $warningMessage = "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
                    $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
                }
                Write-StatusMessage -Event "Error" -Message $warningMessage
                Write-SummaryMessage -Event "Failed" -Message $errorMessage
                exit
            }
        }
        else {
            Write-SummaryMessage -Event "Failed" -Message "No HelloID Self service Categories have been found with the name [$categoryName]. Either change this to an existing category name or set `$createCategoryIfNotExists = `$true to create it automatically."
            exit
        }
    }
    else {
        Write-StatusMessage -Event Success -Message "Category [$categoryName] already exists in HelloID"
    }

    # Validate access groups
    if (($sampleProductConfig.AccessGroups | Measure-Object).Count -gt 0) {
        $actionMessage = "validating access group(s): [$($sampleProductConfig.AccessGroups -join ', ')]"

        $validatedGroups = 0
        $missingGroups = @()
        foreach ($accessGroup in $sampleProductConfig.AccessGroups) {
            $actionMessage = "validating access group [$accessGroup]"
            $accessGroupExists = $helloIDGroupsInScopeGroupedBySourceAndName.ContainsKey($accessGroup)
            if (-not $accessGroupExists) {
                $missingGroups += $accessGroup
            }
            else {
                $validatedGroups++
            }
        }
        
        if (($missingGroups | Measure-Object).Count -gt 0) {
            Write-StatusMessage -Event Warning -Message "Access group(s) [$($missingGroups -join ', ')] do not exist in HelloID. Products will be created but these groups will NOT be added."
        }
        
        if ($validatedGroups -gt 0) {
            Write-StatusMessage -Event Success -Message "Validated: $validatedGroups access group(s) exist in HelloID"
        }
    }
    else {
        Write-StatusMessage -Event Information -Message "No access groups configured. Products will only be visible to product owner/manager."
    }

    # Build product objects for all source objects
    # In test run mode, we build all products but limit operations per type later
    $actionMessage = "building product objects for $(($sourceObjectsInScope | Measure-Object).Count) source object(s)"
    Write-StatusMessage -Event Information -Message "Building product objects for $(($sourceObjectsInScope | Measure-Object).Count) source object(s)..."
    $productObjects = [System.Collections.ArrayList]@()
    foreach ($sourceObjectInScope in $sourceObjectsInScope) {
        $actionMessage = "processing source object [$($sourceObjectInScope.DisplayName) ($($sourceObjectInScope.$sourceObjectUniqueProperty))]"
        # Get product configuration from configuration function
        $newProductConfigSplatParams = @{
            SourceObject               = $sourceObjectInScope
            ProductIdentifierPrefix    = $productIdentifierPrefix
            SourceObjectUniqueProperty = $sourceObjectUniqueProperty
        }
        $productConfig = New-HelloIDProductConfiguration @newProductConfigSplatParams
        
        # Calculate product code to check if product already exists
        $calculatedProductCode = $productConfig.Code.Replace("-", "")
        $productAlreadyExists = $calculatedProductCode -in $helloIDSelfServiceProductsInScope.code
        
        # Define ManagedBy Group
        if ( $resourceOwnerMode -eq "Calculated" ) {
            # Calculate resource owner group using helper function
            $resourceOwnerGroupName = Get-ResourceOwnerGroupName -SourceObjectDisplayName $sourceObjectInScope.DisplayName -IncludeSourcePrefix $true
        }
        else {
            # Fixed mode - use specified resource owner group
            $resourceOwnerGroupName = $productResourceOwner
        }

        # Get HelloID Resource Owner Group and create if it doesn't exist
        $helloIDResourceOwnerGroup = $null
        if (-not[string]::IsNullOrEmpty($resourceOwnerGroupName)) {
            $helloIDResourceOwnerGroup = $helloIDGroupsInScopeGroupedBySourceAndName["$($resourceOwnerGroupName)"]
            
            # Validate that only one group is found (not multiple with the same name)
            if (($helloIDResourceOwnerGroup | Measure-Object).Count -gt 1) {
                $errorMessage = "Found [$(($helloIDResourceOwnerGroup | Measure-Object).Count)] groups with the name [$resourceOwnerGroupName]. Only one unique group (Source + Name combination) is allowed per resource owner group name. Please clean up the duplicate groups in HelloID so that the Source/Name combination is unique."
                Write-StatusMessage -Event "Error" -Message $errorMessage
                Write-SummaryMessage -Event "Failed" -Message $errorMessage
                exit
            }
            
            if ($null -eq $helloIDResourceOwnerGroup) {
                # Only create group if:
                # 1. It's a Local group (otherwise sync should handle this)
                # 2. Product doesn't already exist (if it exists, updateResourceOwnerGroupOnNameChange will handle group rename)
                if ($resourceOwnerGroupName -like "Local/*" -and -not $productAlreadyExists) {
                    # Create HelloID Resource Owner Group
                    try {
                        $actionMessage = "creating new resource owner group [$resourceOwnerGroupName] for product [$($productConfig.Name)]"
                        $helloIDGroupBody = @{
                            Name      = "$($resourceOwnerGroupName.replace('Local/', ''))"
                            IsEnabled = $true
                            Source    = "Local"
                        }

                        $createHelloIDGroupSplatParams = @{
                            Uri     = "$($helloIDPortalBaseUrl)/api/v1/groups"
                            Method  = 'POST'
                            Headers = $helloIDHeaders
                            Body    = ($helloIDGroupBody | ConvertTo-Json -Depth 10)
                        }

                        if ($dryRun -eq $false) {
                            $helloIDResourceOwnerGroup = Invoke-HelloIDRestMethod @createHelloIDGroupSplatParams
                            
                            # Add newly created group to the hashtable so it can be reused for subsequent products
                            $helloIDGroupsInScopeGroupedBySourceAndName[$resourceOwnerGroupName] = $helloIDResourceOwnerGroup
        
                            if ($verboseLogging -eq $true) {
                                Write-Verbose "Successfully created new resource owner group [$($resourceOwnerGroupName)] for HelloID Self service Product [$($productConfig.Name)]"
                            }
                        }
                        else {
                            if ($verboseLogging -eq $true) {
                                Write-Verbose "DryRun: Would create new resource owner group [$($resourceOwnerGroupName)] for HelloID Self service Product [$($productConfig.Name)]"
                                Write-StatusMessage -Event Information -Message "DryRun: Would create new resource owner group [$($resourceOwnerGroupName)] for HelloID Self service Product [$($productConfig.Name)]"
                            }
                        }
                    }
                    catch {
                        $ex = $PSItem
                        if ($($ex.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") -or
                            $($ex.Exception.GetType().FullName -eq "System.Net.WebException")) {
                            $errorObj = Resolve-HelloIDError -ErrorObject $ex
                            $warningMessage = "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
                            $errorMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
                        }
                        else {
                            $warningMessage = "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
                            $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
                        }
                        Write-StatusMessage -Event "Error" -Message $warningMessage
                        Write-SummaryMessage -Event "Failed" -Message $errorMessage
                        exit
                    }
                }
                elseif ($productAlreadyExists) {
                    if ($verboseLogging -eq $true) {
                        Write-Verbose "Skipping resource owner group creation for existing product [$($productConfig.Name)]. Group [$($resourceOwnerGroupName)] not found, but will be handled by updateResourceOwnerGroupOnNameChange if needed."
                    }
                }
                else {
                    if ($verboseLogging -eq $true) {
                        Write-Verbose "No resource owner group [$($resourceOwnerGroupName)] found for HelloID Self service Product [$($productConfig.Name)]"
                    }
                }
            }
        }

        # Define actions for product
        $actionMessage = "defining actions for HelloID Self service Product [$($productConfig.Name)]"
        #region Define On Request actions
        $onRequestActions = [System.Collections.Generic.list[object]]@()
        $productConfig.onRequest | ForEach-Object {
            $agentPoolId = $null
            if (-not[String]::IsNullOrEmpty($_.agentPoolName)) {
                $agentPool = $helloIDAgentPoolsGrouped["$($_.agentPoolName)"]
                if ($null -eq $agentPool) {
                    $errorMessage = "No agent pool found with name [$($_.agentPoolName)]. Please check your configuration and ensure the specified agent pool exists in HelloID."
                    Write-StatusMessage -Event "Error" -Message $errorMessage
                    Write-SummaryMessage -Event "Failed" -Message $errorMessage
                    exit
                }
                $agentPoolId = $helloIDAgentPoolsGrouped["$($_.agentPoolName)"].agentPoolGUID
            }
            else {
                $agentPoolId = "$($defaultHelloIDAgentPool.agentPoolGUID)" # Use default agent pool if not specified
            }

            [void]$onRequestActions.Add([PSCustomObject]@{
                    id          = "" # supplying an id when creating a product action is not supported. You have to leave the 'id' property empty or leave the property out alltogether when creating a new product action
                    name        = $_.name
                    script      = Get-Variable -Name $_.scriptVariableName -ValueOnly
                    agentPoolId = $agentPoolId
                    runInCloud  = $_.runInCloud
                })
        }
        #endregion Define On Request actions

        #region Define On Approve actions
        $onApproveActions = [System.Collections.Generic.list[object]]@()
        $productConfig.onApprove | ForEach-Object {
            $agentPoolId = $null
            if (-not[String]::IsNullOrEmpty($_.agentPoolName)) {
                $agentPool = $helloIDAgentPoolsGrouped["$($_.agentPoolName)"]
                if ($null -eq $agentPool) {
                    $errorMessage = "No agent pool found with name [$($_.agentPoolName)]. Please check your configuration and ensure the specified agent pool exists in HelloID."
                    Write-StatusMessage -Event "Error" -Message $errorMessage
                    Write-SummaryMessage -Event "Failed" -Message $errorMessage
                    exit
                }
                $agentPoolId = $helloIDAgentPoolsGrouped["$($_.agentPoolName)"].agentPoolGUID
            }
            else {
                $agentPoolId = "$($defaultHelloIDAgentPool.agentPoolGUID)" # Use default agent pool if not specified
            }

            [void]$onApproveActions.Add([PSCustomObject]@{
                    id          = "" # supplying an id when creating a product action is not supported. You have to leave the 'id' property empty or leave the property out alltogether when creating a new product action
                    name        = $_.name
                    script      = Get-Variable -Name $_.scriptVariableName -ValueOnly
                    agentPoolId = $agentPoolId
                    runInCloud  = $_.runInCloud
                })
        }
        #endregion Define On Approve actions

        #region Define On Deny actions
        $onDenyActions = [System.Collections.Generic.list[object]]@()
        $productConfig.onDeny | ForEach-Object {
            $agentPoolId = $null
            if (-not[String]::IsNullOrEmpty($_.agentPoolName)) {
                $agentPool = $helloIDAgentPoolsGrouped["$($_.agentPoolName)"]
                if ($null -eq $agentPool) {
                    $errorMessage = "No agent pool found with name [$($_.agentPoolName)]. Please check your configuration and ensure the specified agent pool exists in HelloID."
                    Write-StatusMessage -Event "Error" -Message $errorMessage
                    Write-SummaryMessage -Event "Failed" -Message $errorMessage
                    exit
                }
                $agentPoolId = $helloIDAgentPoolsGrouped["$($_.agentPoolName)"].agentPoolGUID
            }
            else {
                $agentPoolId = "$($defaultHelloIDAgentPool.agentPoolGUID)" # Use default agent pool if not specified
            }

            [void]$onDenyActions.Add([PSCustomObject]@{
                    id          = "" # supplying an id when creating a product action is not supported. You have to leave the 'id' property empty or leave the property out alltogether when creating a new product action
                    name        = $_.name
                    script      = Get-Variable -Name $_.scriptVariableName -ValueOnly
                    agentPoolId = $agentPoolId
                    runInCloud  = $_.runInCloud
                })
        }
        #endregion Define On Deny actions

        #region Define On Return actions
        $onReturnActions = [System.Collections.Generic.list[object]]@()
        $productConfig.onReturn | ForEach-Object {
            $agentPoolId = $null
            if (-not[String]::IsNullOrEmpty($_.agentPoolName)) {
                $agentPool = $helloIDAgentPoolsGrouped["$($_.agentPoolName)"]
                if ($null -eq $agentPool) {
                    $errorMessage = "No agent pool found with name [$($_.agentPoolName)]. Please check your configuration and ensure the specified agent pool exists in HelloID."
                    Write-StatusMessage -Event "Error" -Message $errorMessage
                    Write-SummaryMessage -Event "Failed" -Message $errorMessage
                    exit
                }
                $agentPoolId = $helloIDAgentPoolsGrouped["$($_.agentPoolName)"].agentPoolGUID
            }
            else {
                $agentPoolId = "$($defaultHelloIDAgentPool.agentPoolGUID)" # Use default agent pool if not specified
            }

            [void]$onReturnActions.Add([PSCustomObject]@{
                    id          = "" # supplying an id when creating a product action is not supported. You have to leave the 'id' property empty or leave the property out alltogether when creating a new product action
                    name        = $_.name
                    script      = Get-Variable -Name $_.scriptVariableName -ValueOnly
                    agentPoolId = $agentPoolId
                    runInCloud  = $_.runInCloud
                })
        }
        #endregion Define On Return actions

        #region Define On Withdrawn actions
        $onWithdrawnActions = [System.Collections.Generic.list[object]]@()
        $productConfig.onWithdrawn | ForEach-Object {
            $agentPoolId = $null
            if (-not[String]::IsNullOrEmpty($_.agentPoolName)) {
                $agentPool = $helloIDAgentPoolsGrouped["$($_.agentPoolName)"]
                if ($null -eq $agentPool) {
                    $errorMessage = "No agent pool found with name [$($_.agentPoolName)]. Please check your configuration and ensure the specified agent pool exists in HelloID."
                    Write-StatusMessage -Event "Error" -Message $errorMessage
                    Write-SummaryMessage -Event "Failed" -Message $errorMessage
                    exit
                }
                $agentPoolId = $helloIDAgentPoolsGrouped["$($_.agentPoolName)"].agentPoolGUID
            }
            else {
                $agentPoolId = "$($defaultHelloIDAgentPool.agentPoolGUID)" # Use default agent pool if not specified
            }

            [void]$onWithdrawnActions.Add([PSCustomObject]@{
                    id          = "" # supplying an id when creating a product action is not supported. You have to leave the 'id' property empty or leave the property out alltogether when creating a new product action
                    name        = $_.name
                    script      = Get-Variable -Name $_.scriptVariableName -ValueOnly
                    agentPoolId = $agentPoolId
                    runInCloud  = $_.runInCloud
                })
        }
        #endregion Define On Withdrawn actions

        #region Define Access Groups
        $actionMessage = "defining access groups for HelloID Self service Product [$($productConfig.Name)]"
        $accessGroupsArray = [System.Collections.ArrayList]@()
        if (($productConfig.AccessGroups | Measure-Object).Count -gt 0) {
            foreach ($accessGroup in $productConfig.AccessGroups) {
                $helloIDAccessGroup = $helloIDGroupsInScopeGroupedBySourceAndName["$accessGroup"]
                if (-not $null -eq $helloIDAccessGroup) {
                    $groupObject = @{
                        id   = $helloIDAccessGroup.groupGuid
                        name = $helloIDAccessGroup.name
                    }
                    [void]$accessGroupsArray.Add($groupObject)
                    
                    if ($verboseLogging -eq $true) {
                        Write-Verbose "Adding access group [$($helloIDAccessGroup.Name)] to product [$($sourceObjectInScope.DisplayName)]"
                    }
                }
                else {
                    if ($verboseLogging -eq $true) {
                        Write-Verbose "Access group [$accessGroup] does not exist in HelloID - skipping for product [$($sourceObjectInScope.DisplayName)]"
                    }
                }
            }
        }
        #endregion Define Access Groups
        $actionMessage = "building product object for HelloID Self service Product [$($productConfig.Name)]"
        # Build product object directly
        $productObject = [PSCustomObject]@{
            # General Properties
            sourceIdentifier           = $productConfig.SourceIdentifier
            name                       = $productConfig.Name
            description                = $productConfig.Description
            # Remove dashes and convert to uppercase for HelloID compatibility
            code                       = $productConfig.Code.Replace("-", "")#.ToUpper()
            
            # Resource Owner
            resourceOwnerGroup         = [PSCustomObject]@{
                id = $helloIDResourceOwnerGroup.groupGuid
            }
            
            # Approval & Workflow
            approvalWorkflow           = if ($productConfig.ApprovalWorkflowId) { 
                [PSCustomObject]@{
                    id = $productConfig.ApprovalWorkflowId
                }
            }
            else { 
                $null 
            }
            
            # Pricing
            showPrice                  = $productConfig.ShowPrice
            price                      = $productConfig.Price
            
            # Visibility & Access
            visibility                 = $productConfig.Visibility
            requestComment             = $productConfig.RequestCommentOption
            allowMultipleRequests      = $productConfig.AllowMultipleRequests
            
            # Limits & Risk
            maxCount                   = $productConfig.MaxCount
            hasRiskFactor              = $productConfig.HasRiskFactor
            riskFactor                 = $productConfig.RiskFactor
            
            # Appearance
            icon                       = $productConfig.Icon
            useFaIcon                  = $productConfig.UseFaIcon
            faIcon                     = if ($productConfig.UseFaIcon -and -not [string]::IsNullOrEmpty($productConfig.FaIcon)) { 
                "fa-$($productConfig.FaIcon)" 
            }
            else { 
                $null 
            }
            
            # Category
            categories                 = @(
                [PSCustomObject]@{
                    id = "$($helloIDSelfserviceCategoriesGrouped[$productConfig.Category].selfServiceCategoryGUID)"
                }
            )
            
            # Agent Pool
            agentPool                  = [PSCustomObject]@{
                id = "$($helloIDAgentPoolsInScope.agentPoolGUID)"
            }
            
            # Lifecycle
            returnOnUserDisable        = $productConfig.ReturnOnUserDisable
            
            # Form
            dynamicForm                = if ($productConfig.FormId) { 
                [PSCustomObject]@{ id = $productConfig.FormId } 
            }
            else { 
                $null 
            }

            # Actions
            onRequest                  = $onRequestActions
            onApprove                  = $onApproveActions
            onDeny                     = $onDenyActions
            onReturn                   = $onReturnActions
            onWithdrawn                = $onWithdrawnActions

            # Access Groups
            accessGroups               = $accessGroupsArray
            
            # Time Limit
            hasTimeLimit               = $productConfig.HasTimeLimit
            managerCanOverrideDuration = $productConfig.ManagerCanOverrideDuration
            limitType                  = $productConfig.LimitType
            ownershipMaxDuration       = $productConfig.OwnershipMaxDuration
        }

        [void]$productObjects.Add($productObject)
    }

    # Build action name to script variable mapping from product definitions
    # This allows automatic detection of which script variable corresponds to which action name
    $actionMessage = "building action name to script variable mapping from product definitions"
    $actionScriptMapping = @{}
    if (($productObjects | Measure-Object).Count -gt 0) {
        $sampleProduct = $productObjects[0]
        
        foreach ($actionType in @("onRequest", "onApprove", "onDeny", "onReturn", "onWithdrawn")) {
            if ($null -ne $sampleProduct.$actionType) {
                foreach ($action in $sampleProduct.$actionType) {
                    # Store the mapping: ActionName -> ScriptContent
                    # We'll match this later to find which variable contains this script
                    if (-not [string]::IsNullOrEmpty($action.name) -and -not [string]::IsNullOrEmpty($action.script)) {
                        $actionScriptMapping[$action.name] = $action.script
                    }
                }
            }
        }
        
        if ($verboseLogging -eq $true) {
            Write-Verbose "Built action-to-script mapping for $(($actionScriptMapping | Measure-Object).Count) action(s)"
        }
    }

    # Define product to create
    $actionMessage = "defining products to create based on comparison of source data and existing HelloID products in scope"
    $newProducts = [System.Collections.ArrayList]@()
    $newProducts = $productObjects | Where-Object { $_.Code -notin $helloIDSelfServiceProductsInScope.code }

    # Define products to revoke
    $actionMessage = "defining products to revoke based on comparison of source data and existing HelloID products in scope"
    $obsoleteProducts = [System.Collections.ArrayList]@()
    $obsoleteProducts = $helloIDSelfServiceProductsInScope | Where-Object { $_.code -notin $productObjects.Code }

    # Define products already existing
    $actionMessage = "defining products already existing based on comparison of source data and existing HelloID products in scope"
    $existingProducts = [System.Collections.ArrayList]@()
    $existingProducts = $productObjects | Where-Object { $_.code -in $helloIDSelfServiceProductsInScope.Code }

    # Define total products (existing + new products)
    $totalProducts = ($(($existingProducts | Measure-Object).Count) + $(($newProducts | Measure-Object).Count))

    # Apply test run limits per operation type
    if ($testRun -eq $true) {
        $actionMessage = "applying test run limits to operations"
        $originalCreateCount = ($newProducts | Measure-Object).Count
        $originalUpdateCount = ($existingProducts | Measure-Object).Count
        $originalDeleteCount = ($obsoleteProducts | Measure-Object).Count
        
        $limitApplied = $false
        
        # Limit creates
        if ($testRunMaxCreates -ge 0 -and $originalCreateCount -gt $testRunMaxCreates) {
            Write-StatusMessage -Event Warning -Message "Test run: Limiting creates from $originalCreateCount to $testRunMaxCreates"
            $newProducts = [System.Collections.ArrayList]@($newProducts | Select-Object -First $testRunMaxCreates)
            $limitApplied = $true
        }
        
        # Limit updates (only if update flags are enabled)
        if ($overwriteExistingProduct -eq $true -or $overwriteExistingProductAction -eq $true -or $addMissingProductAction -eq $true -or $removeUnconfiguredActions -eq $true -or $accessGroupUpdateBehavior -ne "None") {
            if ($testRunMaxUpdates -ge 0 -and $originalUpdateCount -gt $testRunMaxUpdates) {
                Write-StatusMessage -Event Warning -Message "Test run: Limiting updates from $originalUpdateCount to $testRunMaxUpdates"
                $existingProducts = [System.Collections.ArrayList]@($existingProducts | Select-Object -First $testRunMaxUpdates)
                $limitApplied = $true
            }
        }
        
        # Limit deletes
        if ($testRunMaxDeletes -ge 0 -and $originalDeleteCount -gt $testRunMaxDeletes) {
            Write-StatusMessage -Event Warning -Message "Test run: Limiting deletes from $originalDeleteCount to $testRunMaxDeletes"
            $obsoleteProducts = [System.Collections.ArrayList]@($obsoleteProducts | Select-Object -First $testRunMaxDeletes)
            $limitApplied = $true
        }
        
        if ($limitApplied) {
            $finalCreateCount = ($newProducts | Measure-Object).Count
            $finalUpdateCount = ($existingProducts | Measure-Object).Count
            $finalDeleteCount = ($obsoleteProducts | Measure-Object).Count
            Write-StatusMessage -Event Success -Message "Test run: Will perform $finalCreateCount create(s), $finalUpdateCount update(s), $finalDeleteCount delete(s)"
        }
        else {
            Write-StatusMessage -Event Information -Message "Test run: All operations are within limits ($originalCreateCount creates, $originalUpdateCount updates, $originalDeleteCount deletes)"
        }
    }
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") -or
        $($ex.Exception.GetType().FullName -eq "System.Net.WebException")) {
        $errorObj = Resolve-HelloIDError -ErrorObject $ex
        $warningMessage = "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
        $errorMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
    }
    else {
        $warningMessage = "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
    }
    Write-StatusMessage -Event "Error" -Message $warningMessage
    Write-SummaryMessage -Event "Failed" -Message $errorMessage
    exit
}

Write-StatusMessage -Event Information -Message "------[Summary]------"

Write-StatusMessage -Event Information -Message "Total source objects in scope [$(($sourceObjectsInScope | Measure-Object).Count)]"

if ($overwriteExistingProduct -eq $true -or $overwriteExistingProductAction -eq $true -or $addMissingProductAction -eq $true -or $removeUnconfiguredActions -eq $true -or $accessGroupUpdateBehavior -ne "None") {
    Write-StatusMessage -Event Information "Total HelloID Self service Product(s) already exist (and will be updated) [$(($existingProducts | Measure-Object).Count)]"
    
    # Show what will be updated
    if ($overwriteExistingProduct -eq $true -and ($productPropertiesToUpdate | Measure-Object).Count -gt 0) {
        $propertiesToUpdateString = ($productPropertiesToUpdate | ForEach-Object { $_ }) -join ', '
        Write-StatusMessage -Event Information "  - Overwrite Product Properties: Enabled. Properties to update: [$propertiesToUpdateString]"
    }
    elseif ($overwriteExistingProduct -eq $true) {
        Write-StatusMessage -Event Information "  - Overwrite Product Properties: Enabled. All non-action properties will be updated"
    }
    
    if ($overwriteExistingProductAction -eq $true -or $addMissingProductAction -eq $true -or $removeUnconfiguredActions -eq $true) {
        $actionUpdateMessage = @()
        if ($overwriteExistingProductAction -eq $true) {
            $actionUpdateMessage += "Overwrite existing actions"
        }
        if ($addMissingProductAction -eq $true) {
            $actionUpdateMessage += "Add missing actions"
        }
        if ($removeUnconfiguredActions -eq $true) {
            $actionUpdateMessage += "Remove unconfigured actions"
        }
        $actionUpdateString = $actionUpdateMessage -join ', '
        Write-StatusMessage -Event Information "  - Product Action Updates: Enabled ($actionUpdateString)"
        
        foreach ($actionType in $actionsToUpdate.Keys) {
            $actionNames = $actionsToUpdate[$actionType] -join ', '
            Write-StatusMessage -Event Information "    - [$actionType]: $actionNames"
        }
    }
    
    if ($accessGroupUpdateBehavior -ne "None") {
        Write-StatusMessage -Event Information "  - Access Group Updates: Enabled (Behavior: $accessGroupUpdateBehavior)"
    }
}
else {
    Write-StatusMessage -Event Information -Message "Total HelloID Self service Product(s) already exist (and won't be changed) [$(($existingProducts | Measure-Object).Count)]"
}

# Show resource owner group rename setting (independent of product updates)
if ($updateResourceOwnerGroupOnNameChange -eq $true -and $resourceOwnerMode -eq "Calculated") {
    Write-StatusMessage -Event Information "Resource Owner Group Rename: Enabled. Groups will be renamed when source object names change"
}

Write-StatusMessage -Event Information -Message "Total HelloID Self service Product(s) to create [$(($newProducts | Measure-Object).Count)]"

if ($removeProductBehavior -eq "Remove") {
    Write-StatusMessage -Event Information "Total HelloID Self service Product(s) to remove [$(($obsoleteProducts | Measure-Object).Count)]"
}
elseif ($removeProductBehavior -eq "Disable") {
    Write-StatusMessage -Event Information "Total HelloID Self service Product(s) to disable [$(($obsoleteProducts | Measure-Object).Count)]"
}
else {
    Write-StatusMessage -Event Information "Total obsolete HelloID Self service Product(s) (no action will be taken) [$(($obsoleteProducts | Measure-Object).Count)]"
}

Write-StatusMessage -Event Information -Message "------[Processing]------------------"
try {
    $productCreatesSuccess = 0
    $productCreatesError = 0
    $resourceOwnerGroupRenamesSuccess = 0
    $resourceOwnerGroupRenamesError = 0
    
    # Check if create threshold is exceeded
    $createThresholdExceeded = $false
    if ($null -ne $createThreshold -and ($newProducts | Measure-Object).Count -ge $createThreshold) {
        $createThresholdExceeded = $true
        if ($verboseLogging -eq $true) {
            Write-Verbose "Create threshold exceeded: Would create [$(($newProducts | Measure-Object).Count)] products, but threshold is set to [$createThreshold]"
        }
    }
    
    # Only process products if threshold is not exceeded, or if verbose logging is enabled (for logging skipped products)
    $actionMessage = "creating [$(($newProducts | Measure-Object).Count)] HelloID Self service Products"
    if ($createThresholdExceeded -eq $false -or $verboseLogging -eq $true) {
        foreach ($newProduct in $newProducts) {
            # Skip creation if threshold is exceeded (only reached when verbose logging is enabled)
            if ($createThresholdExceeded -eq $true) {
                if ($verboseLogging -eq $true) {
                    Write-Verbose "Skipping creation of product [$($newProduct.Name)] - create threshold exceeded"
                }
                continue
            }
            try {
                # Create HelloID Self service Product
                $actionMessage = "creating HelloID Self service Product [$($newProduct.name)]"
                # Create custom productbody object
                $createHelloIDSelfServiceProductBody = [PSCustomObject]@{}

                # Copy product properties into productbody object (exclude accessGroups - managed separately)
                $newProduct.psobject.properties | ForEach-Object {
                    if ($_.Name -ne "accessGroups") {
                        $createHelloIDSelfServiceProductBody | Add-Member -MemberType NoteProperty -Name $_.Name -Value $_.Value
                    }
                }
                
                $createHelloIDProductSplatParams = @{
                    Uri     = "$($helloIDPortalBaseUrl)/api/v1/products"
                    Method  = 'POST'
                    Headers = $helloIDHeaders
                    Body    = ($createHelloIDSelfServiceProductBody | ConvertTo-Json -Depth 10)
                }

                if ($dryRun -eq $false) {
                    $createdHelloIDSelfServiceProduct = Invoke-HelloIDRestMethod @createHelloIDProductSplatParams

                    if ($verboseLogging -eq $true) {
                        Write-Verbose "Successfully created HelloID Self service Product [$($createHelloIDSelfServiceProductBody.Name)]"
                    }

                    # Add access groups via separate API calls
                    $actionMessage = "linking access groups to created product [$($createHelloIDSelfServiceProductBody.Name)]"
                    if (($newProduct.accessGroups | Measure-Object).Count -gt 0) {
                        $groupLinkSuccess = 0
                        $groupLinkError = 0
                        
                        foreach ($accessGroup in $newProduct.accessGroups) {
                            $actionMessage = "linking access group [$($accessGroup.name)] to created product [$($createHelloIDSelfServiceProductBody.Name)]"
                            try {
                                $linkAccessGroupToProductBody = [PSCustomObject]@{
                                    groupGuid = $accessGroup.id
                                }
                                
                                $linkAccessGroupToProductSplatParams = @{
                                    Uri     = "$($helloIDPortalBaseUrl)/api/v1/selfserviceproducts/$($createdHelloIDSelfServiceProduct.productId)/groups"
                                    Method  = 'POST'
                                    Headers = $helloIDHeaders
                                    Body    = ($linkAccessGroupToProductBody | ConvertTo-Json -Depth 10)
                                }

                                $linkedAccessGroupToProduct = Invoke-HelloIDRestMethod @linkAccessGroupToProductSplatParams
                                $groupLinkSuccess++
                                
                                if ($verboseLogging -eq $true) {
                                    Write-Verbose "Successfully linked access group [$($accessGroup.name)] to product [$($createHelloIDSelfServiceProductBody.Name)]"
                                }
                            }
                            catch {
                                $groupLinkError++

                                if ($verboseLogging -eq $true) {
                                    $ex = $PSItem
                                    if ($($ex.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") -or
                                        $($ex.Exception.GetType().FullName -eq "System.Net.WebException")) {
                                        $errorObj = Resolve-HelloIDError -ErrorObject $ex
                                        $warningMessage = "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
                                        $errorMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
                                    }
                                    else {
                                        $warningMessage = "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
                                        $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
                                    }
                                    Write-Verbose $warningMessage
                                    Write-Verbose $errorMessage
                                }
                            }
                        }
                        
                        if ($verboseLogging -eq $true) {
                            Write-Verbose "Linked $groupLinkSuccess of $(($newProduct.accessGroups | Measure-Object).Count) access group(s) to product [$($createHelloIDSelfServiceProductBody.Name)]"
                        }
                    }
                }
                else {
                    if ($verboseLogging -eq $true) {
                        Write-Verbose "DryRun: Would create HelloID Self service Product [$($createHelloIDSelfServiceProductBody.name)]"
                        if (($newProduct.accessGroups | Measure-Object).Count -gt 0) {
                            Write-Verbose "DryRun: Would link $(($newProduct.accessGroups | Measure-Object).Count) access group(s) to product"
                        }
                    }
                }
                $productCreatesSuccess++
            }
            catch {
                $productCreatesError++
                    
                if ($verboseLogging -eq $true) {
                    $ex = $PSItem
                    if ($($ex.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") -or
                        $($ex.Exception.GetType().FullName -eq "System.Net.WebException")) {
                        $errorObj = Resolve-HelloIDError -ErrorObject $ex
                        $warningMessage = "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
                        $errorMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
                    }
                    else {
                        $warningMessage = "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
                        $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
                    }
                    Write-Verbose $warningMessage
                    Write-Verbose $errorMessage
                }
                    
                # Skip this product and continue with next
                continue
            }
        }
    }
    if ($dryRun -eq $false) {
        if ($createThresholdExceeded -eq $false -and ($productCreatesSuccess -ge 1 -or $productCreatesError -ge 1)) {
            Write-StatusMessage -Event Information -Message "Created HelloID Self service Products. Success: $($productCreatesSuccess). Error: $($productCreatesError)"
            Write-SummaryMessage -Event Information -Message "Created HelloID Self service Products. Success: $($productCreatesSuccess). Error: $($productCreatesError)"
        }
    }
    else {
        if ($createThresholdExceeded -eq $false) {
            Write-StatusMessage -Event Warning -Message "DryRun: Would create [$(($newProducts | Measure-Object).Count)] HelloID Self service Products"
            Write-SummaryMessage -Event Warning -Message "DryRun: Would create [$(($newProducts | Measure-Object).Count)] HelloID Self service Products"
        }
    }

    $productRemovesSuccess = 0
    $productRemovesError = 0
    $productDisablesSuccess = 0
    $productDisablesError = 0
    $productDisablesSkipped = 0
    $resourceOwnerGroupRemovesSuccess = 0
    $resourceOwnerGroupRemovesError = 0

    # Check if remove threshold is exceeded (only when removeProductBehavior is not 'None')
    $obsoleteProductThresholdExceeded = $false
    if ($removeProductBehavior -ne "None" -and $null -ne $removeThreshold -and ($obsoleteProducts | Measure-Object).Count -ge $removeThreshold) {
        $obsoleteProductThresholdExceeded = $true
        if ($verboseLogging -eq $true) {
            Write-Verbose "Remove threshold exceeded: Would $($removeProductBehavior) [$(($obsoleteProducts | Measure-Object).Count)] products, but threshold is set to [$removeThreshold]"
        }
    }
    
    # Only process products if threshold is not exceeded, or if verbose logging is enabled (for logging skipped products)
    $actionMessage = "processing obsolete HelloID Self service Products"
    if ($obsoleteProductThresholdExceeded -eq $false -or $verboseLogging -eq $true) {
        foreach ($obsoleteProduct in $obsoleteProducts) {
            $actionMessage = "processing obsolete product [$($obsoleteProduct.Name)]"
            # Skip remove/disable if threshold is exceeded (only reached when verbose logging is enabled)
            if ($obsoleteProductThresholdExceeded -eq $true) {
                if ($verboseLogging -eq $true) {
                    Write-Verbose "Skipping $($removeProductBehavior) of product [$($obsoleteProduct.Name)] - remove threshold exceeded"
                }
                continue
            }
            
            if ($removeProductBehavior -eq "Remove") {
                # Remove HelloID Self service Product
                $actionMessage = "removing HelloID Self service Product [$($obsoleteProduct.Name)]"
                try {
                    $deleteProductSplatParams = @{
                        Uri     = "$($helloIDPortalBaseUrl)/api/v1/products/$($obsoleteProduct.productId)"
                        Method  = 'DELETE'
                        Headers = $helloIDHeaders
                    }

                    if ($dryRun -eq $false) {
                        $deletedHelloIDSelfServiceProduct = Invoke-HelloIDRestMethod @deleteProductSplatParams                
        
                        if ($verboseLogging -eq $true) {
                            Write-Verbose "Successfully removed HelloID Self service Product [$($obsoleteProduct.Name)]"
                        }
                        $productRemovesSuccess++
                        
                        # Remove resource owner group
                        if ($removeResourceOwnerGroupWithProduct -eq $true) {
                            $actionMessage = "removing resource owner group for product [$($obsoleteProduct.Name)]"
                            try {
                                $deleteResourceOwnerGroupSplatParams = @{
                                    Uri     = "$($helloIDPortalBaseUrl)/api/v1/groups/$($obsoleteProduct.resourceOwnerGroup.id)"
                                    Method  = 'DELETE'
                                    Headers = $helloIDHeaders
                                }
                                
                                $deletedGroup = Invoke-HelloIDRestMethod @deleteResourceOwnerGroupSplatParams
                                $resourceOwnerGroupRemovesSuccess++
                                
                                if ($verboseLogging -eq $true) {
                                    Write-Verbose "Successfully removed resource owner group [$($obsoleteProduct.resourceOwnerGroup.id)]"
                                }
                            }
                            catch {
                                $resourceOwnerGroupRemovesError++
                                
                                if ($verboseLogging -eq $true) {
                                    $ex = $PSItem
                                    if ($($ex.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") -or
                                        $($ex.Exception.GetType().FullName -eq "System.Net.WebException")) {
                                        $errorObj = Resolve-HelloIDError -ErrorObject $ex
                                        $warningMessage = "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
                                        $errorMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
                                    }
                                    else {
                                        $warningMessage = "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
                                        $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
                                    }
                                    Write-Verbose $warningMessage
                                    Write-Verbose $errorMessage
                                }
                            }
                        }
                    }
                    else {
                        if ($verboseLogging -eq $true) {
                            Write-Verbose "DryRun: Would remove HelloID Self service Product [$($obsoleteProduct.Name)]"
                            if ($removeResourceOwnerGroupWithProduct -eq $true) {
                                Write-Verbose "DryRun: Would also remove resource owner group [$($obsoleteProduct.resourceOwnerGroup.id)]"
                            }
                        }
                    }
                }
                catch {
                    $productRemovesError++
                    
                    if ($verboseLogging -eq $true) {
                        $ex = $PSItem
                        if ($($ex.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") -or
                            $($ex.Exception.GetType().FullName -eq "System.Net.WebException")) {
                            $errorObj = Resolve-HelloIDError -ErrorObject $ex
                            $warningMessage = "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
                            $errorMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
                        }
                        else {
                            $warningMessage = "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
                            $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
                        }
                        Write-Verbose $warningMessage
                        Write-Verbose $errorMessage
                    }
                    
                    # Skip this product and continue with next
                    continue
                }
            }
            elseif ($removeProductBehavior -eq "Disable") {
                # Disable HelloID Self service Product
                $actionMessage = "disabling HelloID Self service Product [$($obsoleteProduct.Name)]"
                try {
                    # Check if product is already disabled
                    if ($obsoleteProduct.Visibility -eq "Disabled") {
                        $productDisablesSkipped++
                        
                        if ($verboseLogging -eq $true) {
                            Write-Verbose "Product [$($obsoleteProduct.Name)] is already disabled - skipping"
                        }
                        continue
                    }
                    
                    # Create custom productbody object
                    $disableHelloIDSelfServiceProductBody = [PSCustomObject]@{}

                    # Copy product properties into productbody object (all but the properties that aren't supported when updating a HelloID Self service Product)
                    $obsoleteProduct.psobject.properties | ForEach-Object {
                        $disableHelloIDSelfServiceProductBody | Add-Member -MemberType NoteProperty -Name $_.Name -Value $_.Value
                    }

                    # Set Visibility to Disabled in product productbody object
                    $disableHelloIDSelfServiceProductBody.Visibility = "Disabled"

                    $disableProductSplatParams = @{
                        Uri     = "$($helloIDPortalBaseUrl)/api/v1/products"
                        Method  = 'POST'
                        Headers = $helloIDHeaders
                        Body    = ($disableHelloIDSelfServiceProductBody | ConvertTo-Json -Depth 10)
                    }
                    if ($dryRun -eq $false) {
                        $disableHelloIDSelfServiceProduct = Invoke-HelloIDRestMethod @disableProductSplatParams

                        if ($verboseLogging -eq $true) {
                            Write-Verbose "Successfully disabled HelloID Self service Product [$($obsoleteProduct.Name)]"
                        }
                        $productDisablesSuccess++
                    }
                    else {
                        if ($verboseLogging -eq $true) {
                            Write-Verbose "DryRun: Would disable HelloID Self service Product [$($obsoleteProduct.Name)]"
                        }
                    }
                }
                catch {
                    $productDisablesError++
                    
                    if ($verboseLogging -eq $true) {
                        $ex = $PSItem
                        if ($($ex.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") -or
                            $($ex.Exception.GetType().FullName -eq "System.Net.WebException")) {
                            $errorObj = Resolve-HelloIDError -ErrorObject $ex
                            $warningMessage = "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
                            $errorMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
                        }
                        else {
                            $warningMessage = "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
                            $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
                        }
                        Write-Verbose $warningMessage
                        Write-Verbose $errorMessage
                    }
                    
                    # Skip this product and continue with next
                    continue
                }
            }
        }
        if ($removeProductBehavior -eq "Remove") {
            if ($dryRun -eq $false) {
                if ($obsoleteProductThresholdExceeded -eq $false -and ($productRemovesSuccess -ge 1 -or $productRemoveserror -ge 1)) {
                    Write-StatusMessage -Event Information -Message "Removed HelloID Self service Products. Success: $($productRemovesSuccess). Error: $($productRemoveserror)"
                    Write-SummaryMessage -Event Information -Message "Removed HelloID Self service Products. Success: $($productRemovesSuccess). Error: $($productRemoveserror)"
                }
                
                # Show resource owner group removal results
                if ($removeResourceOwnerGroupWithProduct -eq $true -and ($resourceOwnerGroupRemovesSuccess -ge 1 -or $resourceOwnerGroupRemovesError -ge 1)) {
                    Write-StatusMessage -Event Information -Message "Removed Resource Owner Groups. Success: $($resourceOwnerGroupRemovesSuccess). Error: $($resourceOwnerGroupRemovesError)"
                    Write-SummaryMessage -Event Information -Message "Removed Resource Owner Groups. Success: $($resourceOwnerGroupRemovesSuccess). Error: $($resourceOwnerGroupRemovesError)"
                }
            }
            else {
                if ($obsoleteProductThresholdExceeded -eq $false) {
                    Write-StatusMessage -Event Warning -Message "DryRun: Would remove [$(($obsoleteProducts | Measure-Object).Count)] HelloID Self service Products"
                    Write-StatusMessage -Event Warning -Message "DryRun: Would remove [$(($obsoleteProducts | Measure-Object).Count)] HelloID Self service Products"
                }
            }
        }
        elseif ($removeProductBehavior -eq "Disable") {
            if ($dryRun -eq $false) {
                if ($obsoleteProductThresholdExceeded -eq $false -and ($productDisablesSuccess -ge 1 -or $productDisablesError -ge 1)) {
                    Write-StatusMessage -Event Information -Message "Disabled HelloID Self service Products. Success: $($productDisablesSuccess). Error: $($productDisablesError). Skipped (already disabled): $($productDisablesSkipped)"
                    Write-SummaryMessage -Event Information -Message "Disabled HelloID Self service Products. Success: $($productDisablesSuccess). Error: $($productDisablesError). Skipped (already disabled): $($productDisablesSkipped)"
                }
                elseif ($obsoleteProductThresholdExceeded -eq $false -and $productDisablesSkipped -ge 1) {
                    Write-StatusMessage -Event Information -Message "All obsolete products already disabled. Skipped: $($productDisablesSkipped)"
                    Write-SummaryMessage -Event Information -Message "All obsolete products already disabled. Skipped: $($productDisablesSkipped)"
                }
            }
            else {
                if ($obsoleteProductThresholdExceeded -eq $false) {
                    Write-StatusMessage -Event Warning -Message "DryRun: Would disable [$(($obsoleteProducts | Measure-Object).Count)] HelloID Self service Products"
                    Write-StatusMessage -Event Warning -Message "DryRun: Would disable [$(($obsoleteProducts | Measure-Object).Count)] HelloID Self service Products"
                }
            }
        }
        else {
            # $removeProductBehavior = "None" - no action taken
            Write-StatusMessage -Event Information -Message "Skipped [$(($obsoleteProducts | Measure-Object).Count)] obsolete HelloID Self service Products (removeProductBehavior is set to 'None')"
            Write-SummaryMessage -Event Information -Message "Skipped [$(($obsoleteProducts | Measure-Object).Count)] obsolete HelloID Self service Products (removeProductBehavior is set to 'None')"
        }
    }

    $productUpdatesSuccess = 0
    $productUpdatesError = 0
    $productUpdatesSkipped = 0
    $productPropertiesUpdatedCount = 0
    $productActionsUpdatedCount = 0
    
    # Check if update threshold is exceeded (only when update settings are enabled)
    $updateThresholdExceeded = $false
    if (($overwriteExistingProduct -eq $true -or $overwriteExistingProductAction -eq $true -or $addMissingProductAction -eq $true -or $removeUnconfiguredActions -eq $true -or $accessGroupUpdateBehavior -ne "None") -and 
        $null -ne $updateThreshold -and ($existingProducts | Measure-Object).Count -ge $updateThreshold) {
        $updateThresholdExceeded = $true
        if ($verboseLogging -eq $true) {
            Write-Verbose "Update threshold exceeded: Would update [$(($existingProducts | Measure-Object).Count)] products, but threshold is set to [$updateThreshold]"
        }
    }
    
    # Only process products if threshold is not exceeded, or if verbose logging is enabled (for logging skipped products)
    $actionMessage = "processing existing HelloID Self service Products for update"
    if ($updateThresholdExceeded -eq $false -or $verboseLogging -eq $true) {
        foreach ($existingProduct in $existingProducts) {
            $actionMessage = "processing product [$($existingProduct.name)] for update"
            # Skip update if threshold is exceeded (only reached when verbose logging is enabled)
            if ($updateThresholdExceeded -eq $true) {
                if ($verboseLogging -eq $true) {
                    Write-Verbose "Skipping update of product [$($existingProduct.Name)] - update threshold exceeded"
                }
                continue
            }
            try {
                # Get basic product info from grouped list
                $basicProductInfo = $null
                $basicProductInfo = $helloIDSelfServiceProductsInScopeGrouped[$existingProduct.Code]
            
                # Fetch full product details if needed (for actions or resource owner group rename)
                $currentProductInHelloID = $null
                if ($null -ne $basicProductInfo -and (
                        $overwriteExistingProductAction -eq $true -or 
                        $addMissingProductAction -eq $true -or 
                        $removeUnconfiguredActions -eq $true -or 
                        ($updateResourceOwnerGroupOnNameChange -eq $true -and $resourceOwnerMode -eq "Calculated")
                    )) {
                    $actionMessage = "retrieving full product details for product [$($existingProduct.name)]"
                    try {
                        $getProductSplatParams = @{
                            Uri     = "$($helloIDPortalBaseUrl)/api/v1/products/$($basicProductInfo.productId)"
                            Method  = 'GET'
                            Headers = $helloIDHeaders
                        }
                        $currentProductInHelloID = Invoke-HelloIDRestMethod @getProductSplatParams
                    
                        if ($verboseLogging -eq $true) {
                            Write-Verbose "Successfully retrieved full product details for [$($currentProductInHelloID.name)]"
                        }
                    }
                    catch {
                        $productUpdatesError++
                        
                        if ($verboseLogging -eq $true) {
                            $ex = $PSItem
                            if ($($ex.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") -or
                                $($ex.Exception.GetType().FullName -eq "System.Net.WebException")) {
                                $errorObj = Resolve-HelloIDError -ErrorObject $ex
                                $warningMessage = "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
                                $errorMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
                            }
                            else {
                                $warningMessage = "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
                                $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
                            }
                            Write-Verbose $warningMessage
                            Write-Verbose $errorMessage
                        }
                        
                        # Skip this product and continue with next
                        continue
                    }
                }
            
                # Update Resource Owner Group name if product name has changed (independent of other updates)
                # Only applies when $resourceOwnerMode = "Calculated"
                if ($updateResourceOwnerGroupOnNameChange -eq $true -and $resourceOwnerMode -eq "Calculated" -and $null -ne $currentProductInHelloID) {
                    $actionMessage = "checking if resource owner group needs to be renamed for product [$($existingProduct.name)]"
                    try {
                        # Get resource owner group info from existing product
                        $currentResourceOwnerGroup = $currentProductInHelloID.resourceOwnerGroup
                    
                        if ($null -ne $currentResourceOwnerGroup -and -not[string]::IsNullOrEmpty($currentResourceOwnerGroup.name)) {
                            # Only rename if it's a Local group (check if name starts with "Local/")
                            if ($currentResourceOwnerGroup.name -like "Local/*") {
                                # Find the corresponding source object for this product (based on product code) using indexed lookup (O(1) performance)
                                $correspondingSourceObject = $sourceObjectsInScopeGrouped[$currentProductInHelloID.code]
                            
                                if ($null -ne $correspondingSourceObject) {
                                    # Calculate expected resource owner group name using helper function
                                    $expectedResourceOwnerGroupName = Get-ResourceOwnerGroupName -SourceObjectDisplayName $correspondingSourceObject.DisplayName -IncludeSourcePrefix $true
                                }
                                else {
                                    # Could not find corresponding source object - skip rename
                                    if ($verboseLogging -eq $true) {
                                        Write-Verbose "Could not find corresponding source object for product [$($currentProductInHelloID.name)] - skipping resource owner group rename"
                                    }
                                    continue
                                }
                            
                                # Check if the current group name differs from expected name
                                if ($currentResourceOwnerGroup.name -ne $expectedResourceOwnerGroupName) {
                                    $actionMessage = "renaming resource owner group from [$($currentResourceOwnerGroup.name)] to [$expectedResourceOwnerGroupName] for product [$($existingProduct.name)]"
                                    if ($verboseLogging -eq $true) {
                                        Write-Verbose "Resource owner group name changed from [$($currentResourceOwnerGroup.name)] to [$expectedResourceOwnerGroupName] for product [$($existingProduct.name)]"
                                        Write-Verbose "Will rename resource owner group"
                                    }
                                
                                    # Calculate new group name using helper function (without source prefix for API)
                                    $newResourceOwnerGroupName = Get-ResourceOwnerGroupName -SourceObjectDisplayName $correspondingSourceObject.DisplayName -IncludeSourcePrefix $false
                                
                                    # Update the group name
                                    $updateGroupBody = @{
                                        Name = $newResourceOwnerGroupName
                                    }
                                
                                    $updateResourceOwnerGroupSplatParams = @{
                                        Uri     = "$($helloIDPortalBaseUrl)/api/v1/groups/$($currentResourceOwnerGroup.id)"
                                        Method  = 'PUT'
                                        Headers = $helloIDHeaders
                                        Body    = ($updateGroupBody | ConvertTo-Json -Depth 10)
                                    }
                                
                                    if ($dryRun -eq $false) {
                                        $updatedResourceOwnerGroup = Invoke-HelloIDRestMethod @updateResourceOwnerGroupSplatParams
                                        $resourceOwnerGroupRenamesSuccess++
                                    
                                        if ($verboseLogging -eq $true) {
                                            Write-Verbose "Successfully renamed resource owner group from [$($currentResourceOwnerGroup.name)] to [$expectedResourceOwnerGroupName]"
                                        }
                                    }
                                    else {
                                        if ($verboseLogging -eq $true) {
                                            Write-Verbose "DryRun: Would rename resource owner group from [$($currentResourceOwnerGroup.name)] to [$expectedResourceOwnerGroupName]"
                                        }
                                    }
                                }
                            }
                            else {
                                if ($verboseLogging -eq $true) {
                                    Write-Verbose "Resource owner group [$($currentResourceOwnerGroup.name)] is not a Local group - skipping rename"
                                }
                            }
                        }
                    }
                    catch {
                        $resourceOwnerGroupRenamesError++
                    
                        if ($verboseLogging -eq $true) {
                            $ex = $PSItem
                            if ($($ex.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") -or
                                $($ex.Exception.GetType().FullName -eq "System.Net.WebException")) {
                                $errorObj = Resolve-HelloIDError -ErrorObject $ex
                                $warningMessage = "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
                                $errorMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
                            }
                            else {
                                $warningMessage = "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
                                $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
                            }
                            Write-Verbose $warningMessage
                            Write-Verbose $errorMessage
                        }
                    }
                }

                # Determine if we need to update this product
                if ($null -ne $basicProductInfo -and ($overwriteExistingProduct -eq $true -or $overwriteExistingProductAction -eq $true -or $addMissingProductAction -eq $true -or $removeUnconfiguredActions -eq $true -or $accessGroupUpdateBehavior -ne "None")) {

                    $actionMessage = "calculating changes for product [$($existingProduct.name)]"
                    # Use detailed product info if available (when updating actions), otherwise use basic info
                    $sourceProduct = if ($null -ne $currentProductInHelloID) { $currentProductInHelloID } else { $basicProductInfo }
                    
                    # Create deep copy of current product via JSON serialization
                    $updateHelloIDSelfServiceProductBody = $sourceProduct | ConvertTo-Json -Depth 10 | ConvertFrom-Json

                    # Calculate changes between current data and provided data
                    # Only compare properties specified in configuration when $overwriteExistingProduct is true
                    if ($overwriteExistingProduct -eq $true) {
                        $splatCompareProperties = @{
                            ReferenceObject  = @($sourceProduct.PSObject.Properties | Where-Object { $_.Name -in $productPropertiesToUpdate })
                            DifferenceObject = @($existingProduct.PSObject.Properties | Where-Object { $_.Name -in $productPropertiesToUpdate })
                        }
                        $changedProperties = $null
                        $changedProperties = (Compare-Object @splatCompareProperties -PassThru)
                        $newProperties = $changedProperties.Where( { $_.SideIndicator -eq "=>" })
                    }
                    else {
                        $newProperties = @()
                    }

                    if (($newProperties | Measure-Object).Count -ge 1 -or $overwriteExistingProductAction -eq $true -or $addMissingProductAction -eq $true -or $removeUnconfiguredActions -eq $true -or $accessGroupUpdateBehavior -ne "None") {
                        # Track if properties were changed
                        $hasPropertyChanges = ($newProperties | Measure-Object).Count -ge 1
                        $hasActionChanges = $false
                        
                        # Update changed properties
                        foreach ($newProperty in $newProperties) {
                            $updateHelloIDSelfServiceProductBody | Add-Member -MemberType NoteProperty -Name $newProperty.Name -Value $newProperty.Value -Force
                        }
                        
                        # Log changed properties
                        if ($verboseLogging -eq $true -and ($newProperties | Measure-Object).Count -ge 1) {
                            $changedPropertyNames = ($newProperties | ForEach-Object { $_.Name }) -join ', '
                            Write-Verbose "Changed properties for product [$($existingProduct.name)]: $changedPropertyNames"
                        }
                        
                        # Process actions only if we have detailed product info (i.e., when action updates are enabled)
                        if ($null -ne $currentProductInHelloID -and ($overwriteExistingProductAction -eq $true -or $addMissingProductAction -eq $true -or $removeUnconfiguredActions -eq $true)) {
                            $actionMessage = "processing actions for product [$($existingProduct.name)]"
                            # Process actions
                            $actionProperties = @("onRequest", "onApprove", "onApprove", "onDeny", "onReturn", "onWithdrawn")
                            # Track changed actions for summary logging
                            $updatedActionsList = [System.Collections.Generic.List[string]]::new()
                            $addedActionsList = [System.Collections.Generic.List[string]]::new()
                            
                            # Process product actions based on configuration
                            foreach ($actionType in $actionsToUpdate.Keys) {
                                $actionMessage = "processing [$actionType] actions for product [$($existingProduct.name)]"
                                $updatedActions = [System.Collections.Generic.list[object]]@()
                            
                                # Get current actions for this action type from HelloID
                                $currentActions = $currentProductInHelloID.$actionType
                            
                                # Get configured action names for this action type
                                $configuredActionNames = $actionsToUpdate[$actionType]
                            
                                if ($verboseLogging -eq $true) {
                                    Write-Verbose "Processing action type [$actionType] with $(($configuredActionNames | Measure-Object).Count) configured action(s)"
                                }
                            
                                # Process each configured action name
                                foreach ($actionName in $configuredActionNames) {
                                    $actionMessage = "processing action [$actionName] of type [$actionType] for product [$($existingProduct.name)]"
                                    # Get the script content from the mapping
                                    $newScriptContent = $actionScriptMapping[$actionName]
                                
                                    if ([string]::IsNullOrEmpty($newScriptContent)) {
                                        if ($verboseLogging -eq $true) {
                                            Write-Verbose "No script found in mapping for action [$actionName] - skipping"
                                        }
                                        continue
                                    }
                                
                                    # Find matching action by name in current product
                                    $matchingCurrentAction = $currentActions | Where-Object { $_.name -eq $actionName } | Select-Object -First 1
                                
                                    if ($null -ne $matchingCurrentAction) {
                                        # Action exists - compare scripts
                                        if ($newScriptContent -ne $matchingCurrentAction.script) {
                                            # Script differs - update with existing action id
                                            $updatedAction = [PSCustomObject]@{
                                                id          = $matchingCurrentAction.id
                                                name        = $actionName
                                                script      = $newScriptContent
                                                agentPoolId = $matchingCurrentAction.agentPoolId
                                                runInCloud  = $matchingCurrentAction.runInCloud
                                            }
                                            [void]$updatedActions.Add($updatedAction)
                                            [void]$updatedActionsList.Add("$actionType.$actionName")
                                        
                                            if ($verboseLogging -eq $true) {
                                                Write-Verbose "Action [$actionName] script differs - will update with id [$($matchingCurrentAction.id)]"
                                            }
                                        }
                                        else {
                                            # Script is the same - keep existing action with id
                                            $unchangedAction = [PSCustomObject]@{
                                                id          = $matchingCurrentAction.id
                                                name        = $matchingCurrentAction.name
                                                script      = $matchingCurrentAction.script
                                                agentPoolId = $matchingCurrentAction.agentPoolId
                                                runInCloud  = $matchingCurrentAction.runInCloud
                                            }
                                            [void]$updatedActions.Add($unchangedAction)
                                        
                                            if ($verboseLogging -eq $true) {
                                                Write-Verbose "Action [$actionName] script unchanged - keeping with id [$($matchingCurrentAction.id)]"
                                            }
                                        }
                                    }
                                    else {
                                        # New action - add without id (if $addMissingProductAction is true)
                                        if ($addMissingProductAction -eq $true) {
                                            # Get agent pool info for new action
                                            $agentPoolId = if ($null -ne $helloIDAgentPoolsInScope.agentPoolGUID) { 
                                                $helloIDAgentPoolsInScope.agentPoolGUID 
                                            }
                                            else { 
                                                $matchingCurrentAction.agentPoolId 
                                            }
                                        
                                            $newAction = [PSCustomObject]@{
                                                id          = ""
                                                name        = $actionName
                                                script      = $newScriptContent
                                                agentPoolId = $agentPoolId
                                                runInCloud  = $false
                                            }
                                            [void]$updatedActions.Add($newAction)
                                            [void]$addedActionsList.Add("$actionType.$actionName")
                                        
                                            if ($verboseLogging -eq $true) {
                                                Write-Verbose "Action [$actionName] is new - will add"
                                            }
                                        }
                                        else {
                                            if ($verboseLogging -eq $true) {
                                                Write-Verbose "Action [$actionName] is new but addMissingProductAction is false - skipping"
                                            }
                                        }
                                    }
                                }
                            
                                # Add actions from current product that are NOT in the configuration
                                # Behavior depends on $removeUnconfiguredActions setting
                                if ($removeUnconfiguredActions -eq $false) {
                                    # Preserve unconfigured actions (default safe behavior)
                                    foreach ($currentAction in $currentActions) {
                                        $isConfigured = $configuredActionNames | Where-Object { $_ -eq $currentAction.name }
                                        if ($null -eq $isConfigured) {
                                            # Action not in configuration - keep as-is
                                            $preservedAction = [PSCustomObject]@{
                                                id          = $currentAction.id
                                                name        = $currentAction.name
                                                script      = $currentAction.script
                                                agentPoolId = $currentAction.agentPoolId
                                                runInCloud  = $currentAction.runInCloud
                                            }
                                            [void]$updatedActions.Add($preservedAction)
                                        
                                            if ($verboseLogging -eq $true) {
                                                Write-Verbose "Action [$($currentAction.name)] not in configuration - preserving"
                                            }
                                        }
                                    }
                                }
                                else {
                                    # Remove unconfigured actions (dangerous - scripts are lost permanently)
                                    $removedActionsList = [System.Collections.Generic.List[string]]::new()
                                    foreach ($currentAction in $currentActions) {
                                        $isConfigured = $configuredActionNames | Where-Object { $_ -eq $currentAction.name }
                                        if ($null -eq $isConfigured) {
                                            # Action not in configuration - will be removed (not added to $updatedActions)
                                            [void]$removedActionsList.Add("$actionType.$($currentAction.name)")
                                        
                                            if ($verboseLogging -eq $true) {
                                                Write-Verbose "Action [$($currentAction.name)] not in configuration - will be REMOVED"
                                            }
                                        }
                                    }
                                    
                                    if (($removedActionsList | Measure-Object).Count -gt 0) {
                                        $hasActionChanges = $true
                                        if ($verboseLogging -eq $true) {
                                            $removedActionsString = $removedActionsList -join ', '
                                            Write-Verbose "Removed actions for product [$($existingProduct.name)]: $removedActionsString"
                                        }
                                    }
                                }
                            
                                # Add the processed actions to the update body
                                $updateHelloIDSelfServiceProductBody | Add-Member -MemberType NoteProperty -Name $actionType -Value $updatedActions -Force
                            }
                        
                            # Preserve action types that are NOT in the configuration
                            foreach ($actionProperty in $actionProperties) {
                                if ($actionProperty -notin $actionsToUpdate.Keys) {
                                    # Keep existing actions for this type as-is
                                    if (($currentProductInHelloID.$actionProperty | Measure-Object).Count -gt 0) {
                                        $updateHelloIDSelfServiceProductBody | Add-Member -MemberType NoteProperty -Name $actionProperty -Value $currentProductInHelloID.$actionProperty -Force
                                    
                                        if ($verboseLogging -eq $true) {
                                            Write-Verbose "Action type [$actionProperty] not in configuration - preserving all $(($currentProductInHelloID.$actionProperty | Measure-Object).Count) action(s)"
                                        }
                                    }
                                }
                            }

                            # Log summary of changed actions
                            if ($verboseLogging -eq $true) {
                                if (($updatedActionsList | Measure-Object).Count -gt 0) {
                                    $updatedActionsString = $updatedActionsList -join ', '
                                    Write-Verbose "Updated actions for product [$($existingProduct.name)]: $updatedActionsString"
                                }
                                if (($addedActionsList | Measure-Object).Count -gt 0) {
                                    $addedActionsString = $addedActionsList -join ', '
                                    Write-Verbose "Added actions for product [$($existingProduct.name)]: $addedActionsString"
                                }
                            }
                            
                            # Track if any actions were changed
                            if (($updatedActionsList | Measure-Object).Count -gt 0 -or ($addedActionsList | Measure-Object).Count -gt 0) {
                                $hasActionChanges = $true
                            }
                        }

                        # Handle access groups if configured for update - via separate API calls
                        $accessGroupsModified = $false
                        if ($accessGroupUpdateBehavior -ne "None" -and ($existingProduct.accessGroups | Measure-Object).Count -gt 0) {
                            $actionMessage = "updating access groups for product [$($existingProduct.name)] with behavior [$accessGroupUpdateBehavior]"
                            # For Replace mode: determine which groups to add/remove
                            if ($accessGroupUpdateBehavior -eq "Replace" -and $null -ne $sourceProduct -and $null -ne $sourceProduct.accessGroups) {
                                # Get current and desired group IDs
                                $currentGroupIds = @($sourceProduct.accessGroups | ForEach-Object { $_.id })
                                $desiredGroupIds = @($existingProduct.accessGroups | ForEach-Object { $_.id })
                                
                                # Determine which groups to remove (in current but not in desired)
                                $groupsToRemove = $sourceProduct.accessGroups | Where-Object { $_.id -notin $desiredGroupIds }
                                
                                # Determine which groups to add (in desired but not in current)
                                $groupsToAdd = $existingProduct.accessGroups | Where-Object { $_.id -notin $currentGroupIds }
                                
                                # Check if any changes are needed
                                if (($groupsToRemove | Measure-Object).Count -eq 0 -and ($groupsToAdd | Measure-Object).Count -eq 0) {
                                    # No changes needed - all desired groups are already present, no extra groups exist
                                    if ($verboseLogging -eq $true) {
                                        Write-Verbose "Replace behavior: Access groups already match configuration for product [$($existingProduct.name)] - skipping"
                                    }
                                }
                                else {
                                    # Remove groups that shouldn't be there
                                    $groupUnlinkSuccess = 0
                                    $groupUnlinkError = 0
                                    $actionMessage = "removing access groups from product [$($existingProduct.name)]"
                                    
                                    if (($groupsToRemove | Measure-Object).Count -gt 0) {
                                        if ($verboseLogging -eq $true) {
                                            Write-Verbose "Replace behavior: Removing $(($groupsToRemove | Measure-Object).Count) group(s) from product [$($existingProduct.name)]"
                                        }
                                        
                                        foreach ($groupToRemove in $groupsToRemove) {
                                            $actionMessage = "unlinking access group [$($groupToRemove.name)] from product [$($existingProduct.name)]"
                                            try {
                                                if ($dryRun -eq $false) {
                                                    $unlinkAccessGroupToProductSplatParams = @{
                                                        Uri     = "$($helloIDPortalBaseUrl)/api/v1/selfserviceproducts/$($sourceProduct.productId)/groups/$($groupToRemove.id)"
                                                        Method  = 'DELETE'
                                                        Headers = $helloIDHeaders
                                                    }
                                                    $unlinkedAccessGroupToProduct = Invoke-HelloIDRestMethod @unlinkAccessGroupToProductSplatParams
                                                    $groupUnlinkSuccess++
                                                    
                                                    if ($verboseLogging -eq $true) {
                                                        Write-Verbose "Successfully unlinked access group [$($groupToRemove.name)] from product [$($existingProduct.name)]"
                                                    }
                                                }
                                                else {
                                                    if ($verboseLogging -eq $true) {
                                                        Write-Verbose "DryRun: Would unlink access group [$($groupToRemove.name)] from product [$($existingProduct.name)]"
                                                    }
                                                }
                                            }
                                            catch {
                                                $groupUnlinkError++
                                                if ($verboseLogging -eq $true) {
                                                    $ex = $PSItem
                                                    if ($($ex.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") -or
                                                        $($ex.Exception.GetType().FullName -eq "System.Net.WebException")) {
                                                        $errorObj = Resolve-HelloIDError -ErrorObject $ex
                                                        $warningMessage = "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
                                                        $errorMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
                                                    }
                                                    else {
                                                        $warningMessage = "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
                                                        $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
                                                    }
                                                    Write-Verbose $warningMessage
                                                    Write-Verbose $errorMessage
                                                }
                                            }
                                        }
                                        
                                        if ($verboseLogging -eq $true -and $dryRun -eq $false) {
                                            Write-Verbose "Removed $groupUnlinkSuccess of $(($groupsToRemove | Measure-Object).Count) unwanted group(s) from product [$($existingProduct.name)]"
                                        }
                                    }
                                    
                                    # Add groups that should be there
                                    $groupLinkSuccess = 0
                                    $groupLinkError = 0
                                    $actionMessage = "adding access groups to product [$($existingProduct.name)]"
                                    
                                    if (($groupsToAdd | Measure-Object).Count -gt 0) {
                                        if ($verboseLogging -eq $true) {
                                            Write-Verbose "Replace behavior: Adding $(($groupsToAdd | Measure-Object).Count) group(s) to product [$($existingProduct.name)]"
                                        }
                                        
                                        foreach ($groupToAdd in $groupsToAdd) {
                                            $actionMessage = "linking access group [$($groupToAdd.name)] to product [$($existingProduct.name)]"
                                            try {
                                                if ($dryRun -eq $false) {
                                                    $linkAccessGroupToProductBody = [PSCustomObject]@{
                                                        groupGuid = $groupToAdd.id
                                                    }

                                                    $linkAccessGroupToProductSplatParams = @{
                                                        Uri     = "$($helloIDPortalBaseUrl)/api/v1/selfserviceproducts/$($existingProduct.productId)/groups"
                                                        Method  = 'POST'
                                                        Headers = $helloIDHeaders
                                                        Body    = ($linkAccessGroupToProductBody | ConvertTo-Json -Depth 10)
                                                    }

                                                    $linkedAccessGroupToProduct = Invoke-HelloIDRestMethod @linkAccessGroupToProductSplatParams
                                                    $groupLinkSuccess++
                                                    
                                                    if ($verboseLogging -eq $true) {
                                                        Write-Verbose "Successfully linked access group [$($groupToAdd.name)] to product [$($existingProduct.name)]"
                                                    }
                                                }
                                                else {
                                                    if ($verboseLogging -eq $true) {
                                                        Write-Verbose "DryRun: Would link access group [$($groupToAdd.name)] to product [$($existingProduct.name)]"
                                                    }
                                                }
                                            }
                                            catch {
                                                $groupLinkError++
                                                if ($verboseLogging -eq $true) {
                                                    $ex = $PSItem
                                                    if ($($ex.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") -or
                                                        $($ex.Exception.GetType().FullName -eq "System.Net.WebException")) {
                                                        $errorObj = Resolve-HelloIDError -ErrorObject $ex
                                                        $warningMessage = "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
                                                        $errorMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
                                                    }
                                                    else {
                                                        $warningMessage = "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
                                                        $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
                                                    }
                                                    Write-Verbose $warningMessage
                                                    Write-Verbose $errorMessage
                                                }
                                            }
                                        }
                                        
                                        if ($verboseLogging -eq $true -and $dryRun -eq $false) {
                                            Write-Verbose "Replace behavior: Added $groupLinkSuccess of $(($groupsToAdd | Measure-Object).Count) missing group(s) to product [$($existingProduct.name)]"
                                        }
                                    }
                                    
                                    $accessGroupsModified = ($groupLinkSuccess -gt 0 -or $groupUnlinkSuccess -gt 0)
                                }
                            }
                            # For Add mode: add groups that don't exist yet
                            elseif ($accessGroupUpdateBehavior -eq "Add") {
                                $groupLinkSuccess = 0
                                $groupLinkError = 0
                                $groupLinkSkipped = 0
                                $actionMessage = "adding access groups to product [$($existingProduct.name)]"
                                
                                foreach ($configuredGroup in $existingProduct.accessGroups) {
                                    $actionMessage = "checking if access group [$($configuredGroup.name)] needs to be added to product [$($existingProduct.name)]"
                                    # Check if group already exists to avoid duplicates
                                    if ($null -ne $sourceProduct -and $null -ne $sourceProduct.accessGroups) {
                                        $groupExists = $sourceProduct.accessGroups | Where-Object { $_.id -eq $configuredGroup.id }
                                        if ($null -ne $groupExists) {
                                            $groupLinkSkipped++
                                            if ($verboseLogging -eq $true) {
                                                Write-Verbose "Access group [$($configuredGroup.name)] already linked to product - skipping"
                                            }
                                            continue
                                        }
                                    }
                                    
                                    try {
                                        if ($dryRun -eq $false) {
                                            $linkAccessGroupToProductBody = [PSCustomObject]@{
                                                groupGuid = $configuredGroup.id
                                            }

                                            $linkAccessGroupToProductSplatParams = @{
                                                Uri     = "$($helloIDPortalBaseUrl)/api/v1/selfserviceproducts/$($existingProduct.productId)/groups"
                                                Method  = 'POST'
                                                Headers = $helloIDHeaders
                                                Body    = ($linkAccessGroupToProductBody | ConvertTo-Json -Depth 10)
                                            }

                                            $linkedAccessGroupToProduct = Invoke-HelloIDRestMethod @linkAccessGroupToProductSplatParams
                                            $groupLinkSuccess++
                                            
                                            if ($verboseLogging -eq $true) {
                                                Write-Verbose "Successfully linked access group [$($configuredGroup.name)] to product [$($existingProduct.name)]"
                                            }
                                        }
                                        else {
                                            if ($verboseLogging -eq $true) {
                                                Write-Verbose "DryRun: Would link access group [$($configuredGroup.name)] to product [$($existingProduct.name)]"
                                            }
                                        }
                                    }
                                    catch {
                                        $groupLinkError++
                                        if ($verboseLogging -eq $true) {
                                            $ex = $PSItem
                                            if ($($ex.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") -or
                                                $($ex.Exception.GetType().FullName -eq "System.Net.WebException")) {
                                                $errorObj = Resolve-HelloIDError -ErrorObject $ex
                                                $warningMessage = "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
                                                $errorMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
                                            }
                                            else {
                                                $warningMessage = "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
                                                $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
                                            }
                                            Write-Verbose $warningMessage
                                            Write-Verbose $errorMessage
                                        }
                                    }
                                }
                                
                                if ($verboseLogging -eq $true -and $dryRun -eq $false) {
                                    Write-Verbose "Add behavior: Linked $groupLinkSuccess new group(s), skipped $groupLinkSkipped existing group(s) for product [$($existingProduct.name)]"
                                }
                                
                                $accessGroupsModified = ($groupLinkSuccess -gt 0)
                            }
                        }
                        
                        if ($hasPropertyChanges -or $hasActionChanges) {
                            # Update HelloID Self service Product
                            $actionMessage = "updating HelloID Self service Product [$($existingProduct.name)]"
                            $updateHelloIDSelfServiceProductSplatParams = @{
                                Uri     = "$($helloIDPortalBaseUrl)/api/v1/products"
                                Method  = 'POST'
                                Headers = $helloIDHeaders
                                Body    = ($updateHelloIDSelfServiceProductBody | ConvertTo-Json -Depth 10)
                            }

                            if ($dryRun -eq $false) {
                                $updatedHelloIDSelfServiceProduct = Invoke-HelloIDRestMethod @updateHelloIDSelfServiceProductSplatParams

                                if ($verboseLogging -eq $true) {
                                    Write-Verbose "Successfully updated HelloID Self service Product [$($updateHelloIDSelfServiceProductBody.Name)]"
                                }
        
                                # Track what was actually updated
                                if ($hasPropertyChanges) {
                                    $productPropertiesUpdatedCount++
                                }
                                if ($hasActionChanges) {
                                    $productActionsUpdatedCount++
                                }
                                if ($accessGroupsModified) {
                                    $productAccessGroupsUpdatedCount++
                                }
        
                                $productUpdatesSuccess++
                            }
                            else {
                                Write-StatusMessage -Event Warning "DryRun: Would update HelloID Self service Product [$($updateHelloIDSelfServiceProductBody.name)]"
                            }
                        }
                        else {
                            if ($dryRun -eq $false) {
                                # No actual changes detected
                                $productUpdatesSkipped++
        
                                if ($verboseLogging -eq $true) {
                                    Write-Verbose "No changes to HelloID Self service Product [$($updateHelloIDSelfServiceProductBody.Name)]"
                                }
                            }
                            else {
                                Write-StatusMessage -Event Warning "DryRun: No changes to HelloID Self service Product [$($updateHelloIDSelfServiceProductBody.Name)]"
                            } 
                        }
                    }
                    else {
                        # Update settings are enabled but no changes detected (no property changes and no action/access group updates needed)
                        if ($dryRun -eq $false) {
                            $productUpdatesSkipped++
                                
                            if ($verboseLogging -eq $true) {
                                Write-Verbose "No changes to HelloID Self service Product [$($existingProduct.Name)] (property update enabled but no differences found)"
                            }
                        }
                        else {
                            if ($verboseLogging -eq $true) {
                                Write-Verbose "DryRun: No changes to HelloID Self service Product [$($existingProduct.Name)]"
                            }
                        }
                    }
                }
            }
            catch {
                $productUpdatesError++
                
                if ($verboseLogging -eq $true) {
                    $ex = $PSItem
                    if ($($ex.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") -or
                        $($ex.Exception.GetType().FullName -eq "System.Net.WebException")) {
                        $errorObj = Resolve-HelloIDError -ErrorObject $ex
                        $warningMessage = "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
                        $errorMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
                    }
                    else {
                        $warningMessage = "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
                        $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
                    }
                    Write-Verbose $warningMessage
                    Write-Verbose $errorMessage
                }
                
                # Skip this product and continue with next
                continue
            }
        }
    }
    if ($dryRun -eq $false) {
        if ($updateThresholdExceeded -eq $false -and ($productUpdatesSuccess -ge 1 -or $productUpdatesError -ge 1 -or $productUpdatesSkipped -ge 1)) {
            Write-StatusMessage -Event Information -Message "Updated HelloID Self service Products. Success: $($productUpdatesSuccess). Skipped: $($productUpdatesSkipped). Error: $($productUpdatesError)"
            Write-SummaryMessage -Event Information -Message "Updated HelloID Self service Products. Success: $($productUpdatesSuccess). Skipped: $($productUpdatesSkipped). Error: $($productUpdatesError)"
            
            # Show detailed breakdown of what was updated
            if ($productPropertiesUpdatedCount -gt 0) {
                Write-StatusMessage -Event Information -Message "  - Products with property updates: $($productPropertiesUpdatedCount)"
                Write-SummaryMessage -Event Information -Message "Products with property updates: $($productPropertiesUpdatedCount)"
            }
            if ($productActionsUpdatedCount -gt 0) {
                Write-StatusMessage -Event Information -Message "  - Products with action updates: $($productActionsUpdatedCount)"
                Write-SummaryMessage -Event Information -Message "Products with action updates: $($productActionsUpdatedCount)"
            }
            if ($productAccessGroupsUpdatedCount -gt 0) {
                Write-StatusMessage -Event Information -Message "  - Products with access group updates: $($productAccessGroupsUpdatedCount)"
                Write-SummaryMessage -Event Information -Message "Products with access group updates: $($productAccessGroupsUpdatedCount)"
            }
        }
        else {
            # No updates were performed - check if this is because update settings are disabled
            if ($overwriteExistingProduct -eq $false -and $overwriteExistingProductAction -eq $false -and $addMissingProductAction -eq $false -and $removeUnconfiguredActions -eq $false -and $accessGroupUpdateBehavior -eq "None") {
                # All update settings are disabled
                Write-StatusMessage -Event Information -Message "Skipped [$(($existingProducts | Measure-Object).Count)] existing HelloID Self service Products (all update settings are disabled)"
                Write-SummaryMessage -Event Information -Message "Skipped [$(($existingProducts | Measure-Object).Count)] existing HelloID Self service Products (all update settings are disabled)"
            }
        }
        
        # Show resource owner group rename results
        if ($updateResourceOwnerGroupOnNameChange -eq $true -and $resourceOwnerMode -eq "Calculated") {
            if ($resourceOwnerGroupRenamesSuccess -ge 1 -or $resourceOwnerGroupRenamesError -ge 1) {
                Write-StatusMessage -Event Information -Message "Renamed Resource Owner Groups. Success: $($resourceOwnerGroupRenamesSuccess). Error: $($resourceOwnerGroupRenamesError)"
                Write-SummaryMessage -Event Information -Message "Renamed Resource Owner Groups. Success: $($resourceOwnerGroupRenamesSuccess). Error: $($resourceOwnerGroupRenamesError)"
            }
        }
    }
    else {
        if ($updateThresholdExceeded -eq $false) {
            Write-StatusMessage -Event Warning -Message "DryRun: Would update [$(($existingProducts | Measure-Object).Count)] HelloID Self service Products"
            Write-StatusMessage -Event Warning -Message "DryRun: Would update [$(($existingProducts | Measure-Object).Count)] HelloID Self service Products"
        }
    }

    # Summary logging - show success/dry-run message first
    if ($dryRun -eq $false) {
        if (-not $createThresholdExceeded -and -not $obsoleteProductThresholdExceeded -and -not $updateThresholdExceeded) {
            # Calculate actual processed products (creates + updates + removes/disables)
            $actualProductsProcessed = ($productCreatesSuccess + $productCreatesError) + 
            ($productUpdatesSuccess + $productUpdatesError + $productUpdatesSkipped) + 
            ($productRemovesSuccess + $productRemoveserror) + 
            ($productDisablesSuccess + $productDisablesError + $productDisablesSkipped)
            
            # Build summary message based on test run status
            if ($testRun -eq $true) {
                $testRunSuffix = " (Test run: limited operations)"
                Write-StatusMessage -Event Success -Message "Successfully processed [$actualProductsProcessed] HelloID Self service Products from [$(($sourceObjectsInScope | Measure-Object).Count)] source objects$testRunSuffix"
                Write-SummaryMessage -Event Success -Message "Successfully processed [$actualProductsProcessed] HelloID Self service Products from [$(($sourceObjectsInScope | Measure-Object).Count)] source objects$testRunSuffix"
            }
            else {
                Write-StatusMessage -Event Success -Message "Successfully synchronized [$(($sourceObjectsInScope | Measure-Object).Count)] source objects to [$totalProducts] HelloID Self service Products"
                Write-SummaryMessage -Event Success -Message "Successfully synchronized [$(($sourceObjectsInScope | Measure-Object).Count)] source objects to [$totalProducts] HelloID Self service Products"
            }
        }
    }
    else {
        Write-StatusMessage -Event Success -Message "DryRun: Would synchronize [$(($sourceObjectsInScope | Measure-Object).Count)] source objects to [$totalProducts] HelloID Self service Products"
        Write-SummaryMessage -Event Success -Message "DryRun: Would synchronize [$(($sourceObjectsInScope | Measure-Object).Count)] source objects to [$totalProducts] HelloID Self service Products"
    }

    # Check if any thresholds were exceeded and show combined summary
    $anyThresholdExceeded = $createThresholdExceeded -or $obsoleteProductThresholdExceeded -or $updateThresholdExceeded
    
    if ($anyThresholdExceeded) {
        Write-StatusMessage -Event "Error" -Message "One or more thresholds exceeded:"
        
        if ($createThresholdExceeded) {
            Write-StatusMessage -Event "Error" -Message "  - Create threshold exceeded: Would create [$(($newProducts | Measure-Object).Count)] products, but threshold is set to [$createThreshold]"
            if ($dryRun -eq $false) {
                Write-SummaryMessage -Event "Failed" -Message "Create threshold exceeded: Would create [$(($newProducts | Measure-Object).Count)] products, but threshold is set to [$createThreshold]. Increase threshold or investigate why so many products would be created."
            }
            else {
                Write-SummaryMessage -Event "Warning" -Message "DryRun: Create threshold would be exceeded: Would create [$(($newProducts | Measure-Object).Count)] products, but threshold is set to [$createThreshold]"
            }
        }
        
        if ($obsoleteProductThresholdExceeded -and $removeProductBehavior -ne "None") {
            Write-StatusMessage -Event "Error" -Message "  - Remove threshold exceeded: Would $($removeProductBehavior) [$(($obsoleteProducts | Measure-Object).Count)] products, but threshold is set to [$removeThreshold]"
            if ($dryRun -eq $false) {
                Write-SummaryMessage -Event "Failed" -Message "Remove threshold exceeded: Would $($removeProductBehavior) [$(($obsoleteProducts | Measure-Object).Count)] products, but threshold is set to [$removeThreshold]. Increase threshold or investigate why so many products are obsolete."
            }
            else {
                Write-SummaryMessage -Event "Warning" -Message "DryRun: Remove threshold would be exceeded: Would $($removeProductBehavior) [$(($obsoleteProducts | Measure-Object).Count)] products, but threshold is set to [$removeThreshold]"
            }
        }
        
        if ($updateThresholdExceeded) {
            Write-StatusMessage -Event "Error" -Message "  - Update threshold exceeded: Would update [$(($existingProducts | Measure-Object).Count)] products, but threshold is set to [$updateThreshold]"
            if ($dryRun -eq $false) {
                Write-SummaryMessage -Event "Failed" -Message "Update threshold exceeded: Would update [$(($existingProducts | Measure-Object).Count)] products, but threshold is set to [$updateThreshold]. Increase threshold or investigate why so many products would be updated."
            }
            else {
                Write-SummaryMessage -Event "Warning" -Message "DryRun: Update threshold would be exceeded: Would update [$(($existingProducts | Measure-Object).Count)] products, but threshold is set to [$updateThreshold]"
            }
        }
        
        # Exit only after all summary logging is complete (only for non-dry-run)
        exit
    }
}
catch {
    # Calculate actual processed products for error message
    $actualProductsProcessed = ($productCreatesSuccess + $productCreatesError) + 
    ($productUpdatesSuccess + $productUpdatesError + $productUpdatesSkipped) + 
    ($productRemovesSuccess + $productRemoveserror) + 
    ($productDisablesSuccess + $productDisablesError + $productDisablesSkipped)
    Write-SummaryMessage -Event "Failed" -Message "Error during synchronization. Processed [$actualProductsProcessed] products before error occurred"

    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq "Microsoft.PowerShell.Commands.HttpResponseException") -or
        $($ex.Exception.GetType().FullName -eq "System.Net.WebException")) {
        $errorObj = Resolve-HelloIDError -ErrorObject $ex
        $warningMessage = "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
        $errorMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
    }
    else {
        $warningMessage = "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        $errorMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
    }
    Write-StatusMessage -Event "Error" -Message $warningMessage
    Write-SummaryMessage -Event "Failed" -Message $errorMessage
    exit
}
