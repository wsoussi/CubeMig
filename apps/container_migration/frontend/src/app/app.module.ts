import { CUSTOM_ELEMENTS_SCHEMA, NgModule, NO_ERRORS_SCHEMA } from '@angular/core';
import { BrowserModule } from '@angular/platform-browser';
import { HttpClientModule } from '@angular/common/http';

import { AppRoutingModule } from './app-routing.module';
import { AppComponent } from './app.component';
import {AppLayoutModule} from './layout/app.layout.module';
import { OverviewComponent } from './pages/overview/overview.component';
import { MigrationComponent } from './pages/migration/migration.component';
import { ConfigComponent } from './pages/config/config.component';
import { LogsComponent } from './pages/logs/logs.component';
import { SimulationComponent } from './pages/simulation/simulation.component';
import { TeeEncapsulationComponent } from './pages/tee-encapsulation/tee-encapsulation.component';
import { CommonModule } from '@angular/common';
import { TableModule } from 'primeng/table';
import { ButtonModule } from 'primeng/button';
import { InputTextModule } from 'primeng/inputtext';
import { DropdownModule } from 'primeng/dropdown';
import { ToggleButtonModule } from 'primeng/togglebutton';
import { InputSwitchModule } from 'primeng/inputswitch';
import { TreeModule } from 'primeng/tree';
import { ScrollPanelModule } from 'primeng/scrollpanel';
import { ContextMenuModule } from 'primeng/contextmenu';
import { DialogModule } from 'primeng/dialog';
import { ToastModule } from 'primeng/toast';
import { ProgressSpinnerModule } from 'primeng/progressspinner';
import { MessagesModule } from 'primeng/messages';
import { MessageModule } from 'primeng/message';
import { FormsModule } from '@angular/forms';
import { MessageService } from 'primeng/api';
import { MarkdownModule } from 'ngx-markdown';

@NgModule({
  declarations: [
    AppComponent,
    OverviewComponent,
    MigrationComponent,
    ConfigComponent,
    LogsComponent,
    SimulationComponent,
    TeeEncapsulationComponent
  ],
  imports: [
    CommonModule,
    FormsModule,
    HttpClientModule,
    AppRoutingModule, 
    AppLayoutModule,
    TableModule, 
    ButtonModule,
    DropdownModule,
    InputTextModule,
    ToggleButtonModule,
    InputSwitchModule,
    TreeModule,
    ContextMenuModule,
    ScrollPanelModule,
    DialogModule,
    ToastModule,
    ProgressSpinnerModule,
    MessagesModule,
    MessageModule,
    // Markdown module for rendering markdown content
    MarkdownModule.forRoot()
  ],
  providers: [MessageService],
  bootstrap: [AppComponent]
})
export class AppModule { }
