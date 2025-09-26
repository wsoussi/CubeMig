import { Component, OnInit } from '@angular/core';
import { MenuItem, MessageService, TreeNode } from 'primeng/api';
import { LogsService } from '../../service/logs.service';
import { MarkdownService } from 'ngx-markdown';
import { HttpErrorResponse } from '@angular/common/http';

@Component({
  selector: 'app-logs',
  templateUrl: './logs.component.html',
  styleUrl: './logs.component.scss'
})
export class LogsComponent implements OnInit {
  
  files: TreeNode[] = [];
  items: MenuItem[] = [];
  selectedFile!: TreeNode;
  viewFileContent: string = '';
  viewedLabel: string = '';
  isMarkdownFile: boolean = false;
  
  constructor(private logService: LogsService, 
              private messageService: MessageService, 
              private markdownService: MarkdownService) {}

  ngOnInit(): void {
    this.getLogStructure();
    this.items = [
      {label: 'Download', icon: 'pi pi-download', command: (event) => this.downloadFile(this.selectedFile)}
    ];
  }

  private getLogStructure() {
    this.logService.getLogStructure().subscribe({
      next: (data: TreeNode[]) => {
        this.files = this.sortTreeNodes(data);
      },
      error: (error: HttpErrorResponse) => {
        this.messageService.add({
          key: 'tst',
          severity: 'error',
          summary: 'Error',
          detail: 'Failed to load log structure'
        });
      }
    });
  }

  private sortTreeNodes(nodes: TreeNode[]): TreeNode[] {
    return nodes.sort((a, b) => {
      // First, sort by whether it's a directory (has children) or file
      const aIsDir = !!a.children;
      const bIsDir = !!b.children;
      if (aIsDir !== bIsDir) {
        return aIsDir ? -1 : 1;
      }
      // Then sort by label
      return a.label!.localeCompare(b.label!);
    });
  }

  viewFile(file: TreeNode) {
    if (file.label && file.label.endsWith('.txt')) {
      this.logService.viewFile(file).subscribe({
        next: (content: string) => {
          this.viewFileContent = content;
          this.viewedLabel = file.label!;
          this.isMarkdownFile = file.label === 'ai_suggestion.txt';
        },
        error: (error: HttpErrorResponse) => {
          this.messageService.add({
            key: 'tst',
            severity: 'error',
            summary: 'Error',
            detail: 'Failed to load file content'
          });
        }
      });
    } else {
      this.messageService.add({
        key: 'tst',
        severity: 'error',
        summary: 'Error',
        detail: 'Only text files can be viewed.'
      });
    }
  }

  nodeSelect(event: any) {
    if (this.isFolder(event.node)) {
      return;
    }
    this.viewFile(this.selectedFile);
    if (event.node.label !== this.viewedLabel) {
      this.viewFileContent = '';
      this.isMarkdownFile = false;
    }
  }

  downloadFile(file: TreeNode) {
    if (file.label && file.label.endsWith('.txt')) {
      this.logService.downloadFile(file).subscribe({
        next: (blob: Blob) => {
          const url = window.URL.createObjectURL(blob);
          const a = document.createElement('a');
          a.href = url;
          // Use the full path hierarchy for the download name
          const path = this.getFullPath(file);
          a.download = path.join('_');
          document.body.appendChild(a);
          a.click();
          document.body.removeChild(a);
          window.URL.revokeObjectURL(url);
        },
        error: (error: HttpErrorResponse) => {
          this.messageService.add({
            key: 'tst',
            severity: 'error',
            summary: 'Error',
            detail: 'Failed to download file'
          });
        }
      });
    } else {
      this.messageService.add({
        key: 'tst',
        severity: 'error',
        summary: 'Error',
        detail: 'Only text files can be downloaded.'
      });
    }
  }

  private getFullPath(node: TreeNode): string[] {
    const path: string[] = [];
    let current: TreeNode | undefined = node;
    while (current) {
      if (current.label) {
        path.unshift(current.label);
      }
      current = current.parent as TreeNode;
    }
    return path;
  }

  private isFolder(file: TreeNode): boolean {
    return !file.label!.includes('.');
  } 
}
